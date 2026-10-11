#include "VL1_D.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <deque>
#include <memory>

constexpr int TAGS = 4; // 4 random tags x 32KB = 4x the cache, so tags fight over rows
constexpr uint64_t LOADS = 1000000;
constexpr uint64_t HANG = 10000; // stalled this long = something's stuck

struct Beat {
    uint32_t addr; // 16byte units, same as Dreq_addr
    uint64_t ready;
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    unsigned seed = argc > 1 ? atoi(argv[1]) : time(nullptr);
    srand(seed);
    printf("seed %u\n", seed);

    // fake ddr3: each word is a hash of its address, so all 256MB exist without storing them
    uint32_t salt = rand();
    auto golden = [&](uint32_t a) {
        uint32_t x = (a >> 2) * 0x9E3779B1u ^ salt;
        x ^= x >> 15;
        x *= 0x85EBCA77u;
        return x ^ (x >> 13);
    };
    uint32_t tags[TAGS];
    for (auto &t : tags) {
        t = rand() % 8192; // all 13 tag bits get exercised
    }
    auto rand_addr = [&] { return tags[rand() % TAGS] << 15 | (uint32_t)(rand() % 8192) * 4; };

    auto top = std::make_unique<VL1_D>();
    top->re = 1;
    top->we = 0;
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

    uint32_t cur = 0;           // MEM's address
    uint32_t nxt = rand_addr(); // EX's address
    uint64_t cyc = 0, loads = 0, stall = 0, stalled_loads = 0, reqs = 0, errors = 0;

    while (loads < LOADS && !Verilated::gotFinish()) {
        // fake EMI: one beat per cycle max, in order
        top->mem_done = !emi.empty() && emi.front().ready <= cyc;
        if (top->mem_done) {
            uint32_t base = emi.front().addr * 16;
            for (int w = 0; w < 4; w++) {
                top->EMI_rdata[w] = golden(base + w * 4);
            }
            emi.pop_front();
        }
        top->req_awck = rand() % 3 == 0;
        top->eval();

        // fake CPU
        if (top->mem_rdy) {
            if (top->D_data_out != golden(cur)) {
                if (errors++ < 10) {
                    printf("cyc %lu: addr 0x%05x got 0x%08x want 0x%08x\n", cyc, cur,
                           top->D_data_out, golden(cur));
                }
            }
            if (stall) {
                stalled_loads++;
            }
            loads++;
            stall = 0;
            top->advance = 1;
            top->Dread_addr = nxt; // EX moves into MEM
            cur = nxt;
            nxt = rand_addr();
        } else {
            if (++stall > HANG) {
                printf("cyc %lu: hung on addr 0x%05x\n", cyc, cur);
                return 1;
            }
            top->advance = 0;
            top->Dread_addr = cur; // CORE's mem_stall ? MEM_memTarget : memTarget
        }
        top->eval();

        // EMI accepts a request this edge
        if (top->Dreq && top->req_awck) {
            last_ready = std::max(cyc + 5 + rand() % 26, last_ready + 1);
            emi.push_back({top->Dreq_addr, last_ready});
            reqs++;
        }

        top->clk = 1;
        top->eval();
        top->clk = 0;
        top->eval();
        cyc++;
    }

    printf("%lu loads, %lu cycles, %lu refills (%lu requests), %lu stalled loads, %lu errors\n",
           loads, cyc, reqs / 4, reqs, stalled_loads, errors);
    return errors != 0;
}
