#include "VL1.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <deque>
#include <memory>
#include <unordered_map>

// Not even gonna lie, I didn't write that testbench bc I just don't feel like doing it

constexpr int TAGS = 4; // per cache, 4x each cache's size so lines get evicted and come back
constexpr uint64_t N = 1000000;  // fetches and D ops, run until both get there
constexpr uint64_t HANG = 10000; // stalled this long = something's stuck
constexpr int JUMP_PCT = 10;     // I: otherwise PC moves on by 4 or 8 like straight-line code
constexpr int I_EDGE_PCT = 3;    // I: jump to the last box of a 16KB chunk
constexpr int STORE_PCT = 30;
constexpr int SAME_BOX_PCT =
    25; // D: next op hits the same 16B box, stresses store->load back to back
constexpr int D_EDGE_PCT =
    3; // D: last box of a 32KB chunk, so crossing accesses spill into the next tag
constexpr int SKIP_PCT = 50;  // I: fetch from pc-4 and skip a word, like after a 64-bit instruction
constexpr int JUMP_BUBBLE_PCT = 5; // I: a taken jump, the window after it is fetched and thrown away
constexpr int REFETCH = 3; // D: bubbles after a replay while IF/ID/EX refill, like CORE's flush

// code lives in the top half of the 256MB (addr bit 27 = 1), data in the bottom half, so D's
// write-backs never land on something I fetches (no self-modifying code)

struct Beat {
    uint32_t data[4]; // taken from ddr3 when EMI accepts the read, so it's in order with writes
    uint64_t ready;
};

struct Op {
    uint32_t addr;
    bool store;
    uint8_t size;  // mem_size: 0 u8, 1 u16, 2 u32
    uint32_t data; // right-aligned, like CORE's store_val
    bool valid;    // false = bubble
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

    // what IF expects, same as RAM.sv: {word at PC+4, word at PC}, each word big-endian
    auto fetch = [&](uint32_t pc) {
        return (uint64_t)__builtin_bswap32(ddr3_word(pc + 4)) << 32 |
               __builtin_bswap32(ddr3_word(pc));
    };

    // what MEM should see: initial contents + every store done so far
    std::unordered_map<uint32_t, uint8_t> stored;
    auto cpu_byte = [&](uint32_t a) {
        auto it = stored.find(a);
        return it != stored.end() ? it->second : init_byte(a);
    };
    auto cpu_word = [&](uint32_t a) { // big-endian: lowest address on top
        return (uint32_t)cpu_byte(a) << 24 | cpu_byte(a + 1) << 16 | cpu_byte(a + 2) << 8 |
               cpu_byte(a + 3);
    };

    uint32_t i_tags[TAGS], d_tags[TAGS];
    for (auto &t : i_tags) {
        t = 8192 + rand() % 8191; // 14-bit tag, top bit set; tag+1 still in the code half
    }
    for (auto &t : d_tags) {
        t = rand() % 4095; // 13-bit tag, top bit clear; tag+1 still in the data half
    }

    auto next_pc = [&](uint32_t pc) {
        int r = rand() % 100;
        if (r < JUMP_PCT) {
            return (i_tags[rand() % TAGS] << 14 | (rand() % 16384)) & ~3u;
        }
        if (r < JUMP_PCT + I_EDGE_PCT) {
            return i_tags[rand() % TAGS] << 14 | (0x3FF0 + (rand() % 4) * 4);
        }
        return (pc + (rand() % 2 ? 4 : 8)) & 0x0FFFFFFF;
    };
    auto rand_op = [&](uint32_t prev) {
        Op op;
        int r = rand() % 100;
        op.addr = r < SAME_BOX_PCT ? (prev & ~15u) | (rand() % 16)
                  : r < SAME_BOX_PCT + D_EDGE_PCT
                      ? d_tags[rand() % TAGS] << 15 | (0x7FF0 + rand() % 16)
                      : d_tags[rand() % TAGS] << 15 | (rand() % 32768);
        op.store = rand() % 100 < STORE_PCT;
        op.size = rand() % 3; // any size at any byte address, loads and stores
        op.data = rand();
        op.valid = true;
        return op;
    };

    // start with garbage in every BRAM and flop, the reset sweeps have to clean it up (needs
    // --x-initial unique)
    Verilated::randReset(2);
    Verilated::randSeed(seed);
    auto top = std::make_unique<VL1>();
    auto set_mem = [&](const Op &op) { // MEM-stage inputs, killed like CORE's isMEM_valid on a replay
        top->re = op.valid && !op.store && !top->D_miss_ff;
        top->we = op.valid && op.store && !top->D_miss_ff;
        top->D_write_addr = op.addr;
        top->mem_size = op.size;
        top->D_data_in = op.data;
    };

    // both latched addresses reset to 0, so the first fetch and the first D op are at 0. That's in
    // the data half, but it's done long before D's sweep ends and anything gets written back
    uint32_t pc = 0;           // PC in IF, its data should be on I_data_out
    const Op bubble = {0, false, 2, 0, false};
    Op cur = {0, false, 2, 0, true}; // MEM
    Op nxt = rand_op(0);             // EX
    uint32_t last_addr = nxt.addr;   // what the next random op is generated near
    std::deque<Op> prog;             // ops to go into EX again after a replay, in program order
    int refetch = 0;
    uint64_t last_progress = 0; // replaying forever never stalls, so watch for no ops finishing
    struct {
        Op op;
        bool valid, bad, stalled;
        uint32_t got;
    } unconf = {bubble, false, false, false, 0}; // left MEM last cycle, real unless D_miss_ff says no
    auto next_op = [&]() {
        if (refetch) {
            refetch--;
            return bubble;
        }
        if (!prog.empty()) {
            Op op = prog.front();
            prog.pop_front();
            return op;
        }
        Op op = rand_op(last_addr);
        last_addr = op.addr;
        return op;
    };
    top->D_advance = 1;
    top->I_addr = 0;
    top->I_even_idx = 0;
    top->I_skip = 0;
    top->I_discard = 0;
    bool nskip = false, ndiscard = false, prev_discard = false; // CORE's IF_skip / IF_redir, they're flops
    top->Dread_addr = 0;
    top->EMI_req_awck = 0;
    top->EMI_mem_done = 0;
    top->rst = 1;
    top->clk = 0;
    top->eval();
    for (int i = 0; i < 4; i++) {
        top->clk = !top->clk;
        top->eval();
    }
    top->rst = 0;
    set_mem(cur); // after reset, so D_miss_ff isn't power-up garbage

    std::deque<Beat> emi; // reads EMI accepted, waiting for their beat
    uint64_t last_ready = 0;

    uint64_t cyc = 0, fetches = 0, ops = 0, loads = 0, stores = 0;
    uint64_t i_stall = 0, d_stall = 0, i_stalled = 0, d_stalled = 0;
    uint64_t i_reqs = 0, d_reqs = 0, wbs = 0, rw_switches = 0, replays = 0, i_replays = 0;
    uint64_t i_progress = 0;
    struct {
        uint32_t pc;
        bool valid, bad, stalled;
        uint64_t got;
    } iunconf = {0, false, false, false, 0}; // fetched last cycle, real unless I_miss_ff says no
    uint64_t i_errors = 0, d_errors = 0, lock_errors = 0;
    int i_run = 0, d_run = 0; // reads accepted in the current 4-read run, mod 4
    bool last_we = false;

    while ((fetches < N || ops < N) && !Verilated::gotFinish()) {
        // fake EMI: one beat per cycle max, in order, whoever asked
        top->EMI_mem_done = !emi.empty() && emi.front().ready <= cyc;
        if (top->EMI_mem_done) {
            for (int w = 0; w < 4; w++) {
                top->EMI_rdata[w] = emi.front().data[w];
            }
            emi.pop_front();
        }
        top->EMI_req_awck = 0;
        top->eval();

        // fake IF: a miss doesn't hold IF, it shows up a cycle later as I_miss_ff and IF goes
        // back to the PC it fetched (CORE's I_kill -> ID_PC)
        if (top->I_miss_ff) {
            if (prev_discard && i_errors++ < 10) {
                printf("cyc %lu: replay from a discarded fetch\n", cyc);
            }
            pc = iunconf.pc;
            iunconf.valid = false;
            i_replays++;
        } else if (iunconf.valid) { // it really happened
            if (iunconf.bad && i_errors++ < 10) {
                printf("cyc %lu: fetch 0x%07x got 0x%016lx want 0x%016lx\n", cyc - 1, iunconf.pc,
                       iunconf.got, fetch(iunconf.pc));
            }
            if (iunconf.stalled) {
                i_stalled++;
            }
            fetches++;
            i_progress = cyc;
            iunconf.valid = false;
        }
        if (cyc - i_progress > HANG) {
            printf("cyc %lu: I stuck on pc 0x%07x\n", cyc, pc);
            return 1;
        }
        prev_discard = top->I_discard;
        bool take = !top->I_miss_ff && top->I_mem_rdy && !top->I_discard;
        if (take) {
            iunconf = {pc, true, top->I_data_out != fetch(pc), i_stall != 0, (uint64_t)top->I_data_out};
            i_stall = 0;
            pc = next_pc(pc);
        } else {
            i_stall++;
        }
        // the window CORE asks for next (IF_PC_tofetch), and what IF_skip / IF_redir will say about it
        uint32_t fa = pc;
        nskip = false;
        ndiscard = false;
        if (take && rand() % 100 < JUMP_BUBBLE_PCT) {
            fa = (i_tags[rand() % TAGS] << 14 | (rand() % 16384)) & ~3u; // whatever followed the jump
            nskip = rand() % 2;
            ndiscard = true;
        } else if (take && rand() % 100 < SKIP_PCT) {
            fa = (pc - 4) & 0x0FFFFFFF;
            nskip = true;
        }
        top->I_addr = fa;
        top->I_even_idx = ((fa >> 5) + (fa >> 4 & 1)) & 0x1FF; // CORE's even_row

        // fake MEM: a miss doesn't stall, it shows up a cycle later as D_miss_ff and replays
        if (top->D_miss_ff) {
            // the op that left MEM last cycle didn't really, the one in MEM now is killed (re/we
            // already dropped), and they go back into the pipeline in program order
            if (nxt.valid) {
                prog.push_front(nxt);
            }
            if (cur.valid) {
                prog.push_front(cur);
            }
            prog.push_front(unconf.op);
            unconf.valid = false;
            cur = bubble;
            nxt = bubble;
            refetch = REFETCH;
            replays++;
        } else if (unconf.valid) { // it really happened
            const Op &op = unconf.op;
            if (op.store) {
                for (int b = 0; b < (1 << op.size); b++) {
                    stored[op.addr + b] = op.data >> 8 * ((1 << op.size) - 1 - b);
                }
                stores++;
            } else {
                if (unconf.bad && d_errors++ < 10) {
                    uint32_t keep = op.size == 2 ? 0xFFFFFFFF : op.size == 1 ? 0xFFFF0000 : 0xFF000000;
                    printf("cyc %lu: load u%d 0x%07x got 0x%08x want 0x%08x\n", cyc - 1, 8 << op.size,
                           op.addr, unconf.got, cpu_word(op.addr) & keep);
                }
                loads++;
            }
            if (unconf.stalled) {
                d_stalled++;
            }
            ops++;
            last_progress = cyc;
            unconf.valid = false;
        }
        if (cyc - last_progress > HANG) {
            printf("cyc %lu: D stuck replaying addr 0x%07x\n", cyc, prog.empty() ? cur.addr : prog.front().addr);
            return 1;
        }

        if (!cur.valid || top->D_mem_rdy) {
            if (cur.valid) {
                // CORE keeps the top 1/2/4 bytes (ram_data_sized), so only those have to be right
                uint32_t keep = cur.size == 2 ? 0xFFFFFFFF : cur.size == 1 ? 0xFFFF0000 : 0xFF000000;
                unconf = {cur, true, !cur.store && (top->D_data_out & keep) != (cpu_word(cur.addr) & keep),
                          d_stall != 0, top->D_data_out & keep};
            }
            d_stall = 0;
            top->D_advance = 1;
            top->Dread_addr = nxt.addr; // EX moves into MEM
            cur = nxt;
            nxt = next_op();
        } else {
            if (++d_stall > HANG) {
                printf("cyc %lu: D hung on addr 0x%07x\n", cyc, cur.addr);
                return 1;
            }
            top->D_advance = 0;
            top->Dread_addr = cur.addr; // CORE's stall ? MEM_memTarget : memTarget
        }
        top->eval();

        // EMI accepts a request this edge, like the real one only while req is up
        top->EMI_req_awck = top->EMI_req && rand() % 3 == 0;
        top->eval();

        if (top->EMI_req_awck) {
            uint32_t base = top->EMI_req_addr * 16;
            bool from_i = !top->EMI_req_we && base >> 27; // code half = I
            // the lock: nobody cuts into the other's 4 refill reads
            if ((from_i && d_run != 0) || (!from_i && i_run != 0)) {
                if (lock_errors++ < 10) {
                    printf("cyc %lu: %s cut into %s's run at 0x%07x\n", cyc, from_i ? "I" : "D",
                           from_i ? "D" : "I", base);
                }
            }
            if (cyc > 0 && top->EMI_req_we != last_we) {
                rw_switches++;
            }
            last_we = top->EMI_req_we;

            if (top->EMI_req_we) { // write: lands in ddr3 now, no mem_done, like the real EMI
                for (int b = 0; b < 16; b++) {
                    if (!(top->EMI_req_msk >> b & 1)) { // msk 1 = byte masked out (DM)
                        ddr3_written[base + b] = top->EMI_req_wd[b / 4] >> 8 * (b % 4);
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
                if (from_i) {
                    i_run = (i_run + 1) % 4;
                    i_reqs++;
                } else {
                    d_run = (d_run + 1) % 4;
                    d_reqs++;
                }
            }
        }

        top->clk = 1;
        top->eval();
        top->clk = 0;
        top->eval();
        set_mem(cur); // the new MEM op's inputs, for the next cycle
        top->I_skip = nskip;
        top->I_discard = ndiscard;
        cyc++;
    }

    printf("%lu cycles\n", cyc);
    printf("I: %lu fetches, %lu refills, %lu stalled, %lu errors\n", fetches, i_reqs / 4, i_stalled,
           i_errors);
    printf("D: %lu ops (%lu loads, %lu stores), %lu refills, %lu box write-backs, %lu stalled, %lu "
           "errors\n",
           ops, loads, stores, d_reqs / 4, wbs, d_stalled, d_errors);
    printf("replays: I %lu, D %lu\n", i_replays, replays);
    printf("EMI: %lu read/write switches, %lu lock errors\n", rw_switches, lock_errors);
    return i_errors || d_errors || lock_errors;
}
