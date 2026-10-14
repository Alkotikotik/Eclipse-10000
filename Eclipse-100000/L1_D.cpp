#include "VL1_D.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <deque>
#include <memory>
#include <unordered_map>
// ngl i didn't fully write it myself bc idk verilator synta

constexpr int TAGS =
    4; // 4 random tags x 32KB = 4x the cache, so dirty lines get evicted and come back
constexpr uint64_t OPS = 1000000;
constexpr uint64_t HANG = 10000; // stalled this long = something's stuck
constexpr int STORE_PCT = 30;
constexpr int SAME_BOX_PCT = 25; // next op hits the same 16B box, stresses store->load back to back

struct Beat {
    uint32_t data[4]; // taken from ddr3 when EMI accepts the read, so it's in order with writes
    uint64_t ready;
};

struct Op {
    uint32_t addr;
    bool store;
    uint8_t size;  // mem_size: 0 u8, 1 u16, 2 u32
    uint32_t data; // right-aligned, like CORE's store_val
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    unsigned seed = argc > 1 ? atoi(argv[1]) : time(nullptr);
    srand(seed);
    printf("seed %u\n", seed);

    // initial ddr3 contents: each word is a hash of its address, so all 256MB exist without storing
    // them
    uint32_t salt = rand();
    auto init_word = [&](uint32_t a) {
        uint32_t x = (a >> 2) * 0x9E3779B1u ^ salt;
        x ^= x >> 15;
        x *= 0x85EBCA77u;
        return x ^ (x >> 13);
    };
    // byte i of a word sits at [8i+7:8i], same as EMI_rdata
    auto init_byte = [&](uint32_t a) { return (uint8_t)(init_word(a) >> 8 * (a & 3)); };

    // fake ddr3: initial contents + whatever EMI writes (evictions)
    std::unordered_map<uint32_t, uint8_t> ddr3_written;
    auto ddr3_word = [&](uint32_t a) {
        uint32_t w = 0;
        for (int i = 0; i < 4; i++) {
            auto it = ddr3_written.find(a + i);
            w |= (uint32_t)(it != ddr3_written.end() ? it->second : init_byte(a + i)) << 8 * i;
        }
        return w;
    };

    // what the CPU should see: initial contents + every store done so far
    std::unordered_map<uint32_t, uint8_t> stored;
    auto cpu_byte = [&](uint32_t a) {
        auto it = stored.find(a);
        return it != stored.end() ? it->second : init_byte(a);
    };
    auto cpu_word = [&](uint32_t a) { // big-endian: lowest address on top
        return (uint32_t)cpu_byte(a) << 24 | cpu_byte(a + 1) << 16 | cpu_byte(a + 2) << 8 |
               cpu_byte(a + 3);
    };

    uint32_t tags[TAGS];
    for (auto &t : tags) {
        t = rand() % 8192; // all 13 tag bits get exercised
    }
    auto rand_op = [&](uint32_t prev) {
        Op op;
        op.addr = rand() % 100 < SAME_BOX_PCT ? (prev & ~15u) | (rand() % 16)
                                              : tags[rand() % TAGS] << 15 | (rand() % 32768);
        op.store = rand() % 100 < STORE_PCT;
        op.size = rand() % 3;
        if (op.store) {
            op.addr &= ~((1u << op.size) - 1); // stores aligned until 4.3, loads go anywhere
        }
        op.data = rand();
        return op;
    };

    // start with garbage in every BRAM and flop, the reset sweep has to clean it up (needs
    // --x-initial unique)
    Verilated::randReset(2);
    Verilated::randSeed(seed);
    auto top = std::make_unique<VL1_D>();
    auto set_mem = [&](const Op &op) { // MEM-stage inputs
        top->re = !op.store;
        top->we = op.store;
        top->D_write_addr = op.addr;
        top->mem_size = op.size;
        top->D_data_in = op.data;
    };

    Op cur = {0, false, 2, 0}; // MEM, Dread_addr_lat resets to 0
    Op nxt = rand_op(0);       // EX
    set_mem(cur);
    top->advance = 1;
    top->Dread_addr = 0;
    top->rst = 1;
    top->clk = 0;
    top->eval();

    for (int i = 0; i < 4; i++) {
        top->clk = !top->clk;
        top->eval();
    }
    top->rst = 0;

    std::deque<Beat> emi; // requests EMI accepted, waiting for their beat
    uint64_t last_ready = 0;

    uint64_t cyc = 0, ops = 0, loads = 0, stores = 0, stall = 0, stalled_ops = 0, reqs = 0, wbs = 0,
             errors = 0;

    while (ops < OPS && !Verilated::gotFinish()) {
        // fake EMI: one beat per cycle max, in order
        top->mem_done = !emi.empty() && emi.front().ready <= cyc;
        if (top->mem_done) {
            for (int w = 0; w < 4; w++) {
                top->EMI_rdata[w] = emi.front().data[w];
            }
            emi.pop_front();
        }
        top->req_awck = rand() % 3 == 0;
        top->eval();

        // fake CPU
        if (top->mem_rdy) {
            if (cur.store) {
                for (int b = 0; b < (1 << cur.size); b++) { // store commits on this edge
                    stored[cur.addr + b] = cur.data >> 8 * ((1 << cur.size) - 1 - b);
                }
                stores++;
            } else {
                // CORE keeps the top 1/2/4 bytes (ram_data_sized), so only those have to be right
                uint32_t keep = cur.size == 2 ? 0xFFFFFFFF : cur.size == 1 ? 0xFFFF0000 : 0xFF000000;
                if ((top->D_data_out & keep) != (cpu_word(cur.addr) & keep)) {
                    if (errors++ < 10) {
                        printf("cyc %lu: load u%d 0x%07x got 0x%08x want 0x%08x\n", cyc,
                               8 << cur.size, cur.addr, top->D_data_out & keep,
                               cpu_word(cur.addr) & keep);
                    }
                }
                loads++;
            }
            if (stall) {
                stalled_ops++;
            }
            ops++;
            stall = 0;
            top->advance = 1;
            top->Dread_addr = nxt.addr; // EX moves into MEM
            cur = nxt;
            nxt = rand_op(cur.addr);
        } else {
            if (++stall > HANG) {
                printf("cyc %lu: hung on addr 0x%07x\n", cyc, cur.addr);
                return 1;
            }
            top->advance = 0;
            top->Dread_addr = cur.addr; // CORE's mem_stall ? MEM_memTarget : memTarget
        }
        top->eval();

        // EMI accepts a request this edge
        if (top->Dreq && top->req_awck) {
            uint32_t base = top->Dreq_addr * 16;
            if (top->Dreq_we) { // write: lands in ddr3 now, no mem_done, like the real EMI
                for (int b = 0; b < 16; b++) {
                    if (!(top->Dreq_msk >> b & 1)) { // msk 1 = byte masked out (DM)
                        ddr3_written[base + b] = top->Dreq_wd_data[b / 4] >> 8 * (b % 4);
                    }
                }
                wbs++;
            } else {
                Beat beat;
                for (int w = 0; w < 4; w++) {
                    beat.data[w] = ddr3_word(base + w * 4);
                }
                last_ready = std::max(cyc + 5 + rand() % 26, last_ready + 1);
                beat.ready = last_ready;
                emi.push_back(beat);
                reqs++;
            }
        }

        top->clk = 1;
        top->eval();
        top->clk = 0;
        top->eval();
        set_mem(cur); // the new MEM op's inputs, for the next cycle
        cyc++;
    }

    printf("%lu ops (%lu loads, %lu stores), %lu cycles, %lu refills (%lu requests), %lu box "
           "write-backs, %lu stalled ops, %lu errors\n",
           ops, loads, stores, cyc, reqs / 4, reqs, wbs, stalled_ops, errors);
    return errors != 0;
}
