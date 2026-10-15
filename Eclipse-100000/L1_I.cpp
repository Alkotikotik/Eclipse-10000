#include "VL1_I.h"
#include "verilated.h"
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <ctime>
#include <deque>
#include <memory>

constexpr int TAGS = 4; // 4 random tags x 16KB = 4x the cache
constexpr uint64_t FETCHES = 1000000;
constexpr uint64_t HANG = 10000; // stalled this long = something's stuck
constexpr int JUMP_PCT = 10;     // otherwise PC moves on by 4 or 8 like straight-line code
constexpr int EDGE_PCT = 3;      // jump to the last box of a 16KB chunk

struct Beat {
    uint32_t data[4];
    uint64_t ready;
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    unsigned seed = argc > 1 ? atoi(argv[1]) : time(nullptr);
    srand(seed);
    printf("seed %u\n", seed);

    // fake ddr3: each word is a hash of its address, byte i of a word at [8i+7:8i] like EMI_rdata
    uint32_t salt = rand();
    auto ddr3_word = [&](uint32_t a) {
        uint32_t x = (a >> 2) * 0x9E3779B1u ^ salt;
        x ^= x >> 15;
        x *= 0x85EBCA77u;
        return x ^ (x >> 13);
    };
    // what IF expects, same as RAM.sv: {word at PC+4, word at PC}, each word big-endian
    auto fetch = [&](uint32_t pc) {
        return (uint64_t)__builtin_bswap32(ddr3_word(pc + 4)) << 32 |
               __builtin_bswap32(ddr3_word(pc));
    };

    uint32_t tags[TAGS];
    for (auto &t : tags) {
        t = rand() % 16384; // all 14 tag bits get exercised
    }
    auto next_pc = [&](uint32_t pc) {
        int r = rand() % 100;
        if (r < JUMP_PCT) {
            return (tags[rand() % TAGS] << 14 | (rand() % 16384)) & ~3u;
        }
        if (r < JUMP_PCT + EDGE_PCT) {
            return tags[rand() % TAGS] << 14 | (0x3FF0 + (rand() % 4) * 4);
        }
        return (pc + (rand() % 2 ? 4 : 8)) & 0x0FFFFFFF;
    };

    Verilated::randReset(2);
    Verilated::randSeed(seed);
    auto top = std::make_unique<VL1_I>();
    top->advance = 1;
    top->I_addr = 0;
    top->rst = 1;
    top->clk = 0;
    top->eval();
    for (int i = 0; i < 4; i++) {
        top->clk = !top->clk;
        top->eval();
    }
    top->rst = 0;

    std::deque<Beat> emi;
    uint64_t last_ready = 0;
    uint32_t cur = 0; // PC in IF, its data should be on I_data_out
    uint64_t cyc = 0, fetches = 0, stall = 0, stalled = 0, reqs = 0, errors = 0;

    while (fetches < FETCHES && !Verilated::gotFinish()) {
        top->mem_done = !emi.empty() && emi.front().ready <= cyc;
        if (top->mem_done) {
            for (int w = 0; w < 4; w++) {
                top->EMI_rdata[w] = emi.front().data[w];
            }
            emi.pop_front();
        }
        top->req_awck = rand() % 3 == 0;
        top->eval();

        if (top->mem_rdy) {
            if (top->I_data_out != fetch(cur)) {
                if (errors++ < 10) {
                    printf("cyc %lu: pc 0x%07x got 0x%016lx want 0x%016lx\n", cyc, cur,
                           (uint64_t)top->I_data_out, fetch(cur));
                }
            }
            if (stall) {
                stalled++;
            }
            fetches++;
            stall = 0;
            cur = next_pc(cur);
            top->advance = 1;
            top->I_addr = cur; // IF_PC_next
        } else {
            if (++stall > HANG) {
                printf("cyc %lu: hung on pc 0x%07x\n", cyc, cur);
                return 1;
            }
            top->advance = 0;
            top->I_addr =
                cur; // stalled: IF_PC_next holds IF_PC so the re-read after the refill hits
        }
        top->eval();

        if (top->I_req && top->req_awck) {
            Beat beat;
            for (int w = 0; w < 4; w++) {
                beat.data[w] = ddr3_word(top->I_req_addr * 16 + w * 4);
            }
            last_ready = std::max(cyc + 5 + rand() % 26, last_ready + 1);
            beat.ready = last_ready;
            emi.push_back(beat);
            reqs++;
        }

        top->clk = 1;
        top->eval();
        top->clk = 0;
        top->eval();
        cyc++;
    }

    printf("%lu fetches, %lu cycles, %lu refills (%lu requests), %lu stalled fetches, %lu errors\n",
           fetches, cyc, reqs / 4, reqs, stalled, errors);
    return errors != 0;
}
