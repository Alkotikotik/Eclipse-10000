#pragma once
// Behavioral stand-in for EMI_1200 + the clock crossing, so CORE can run in Verilator.
// Holds the 256MB that RAM.sv used to, loaded from program.hex the way $readmemh did.
// I didn't write it too, but yeah its a fake EMI.
#include "VCORE.h"
#include "VCORE___024root.h"
#include <cstdint>
#include <cstdio>
#include <deque>
#include <fstream>
#include <string>
#include <vector>

struct FakeEMI {
    static constexpr uint64_t LATENCY =
        20; // CPU cycles accept->beat: ~84ns EMI hit + crossing at 133MHz
    static constexpr uint64_t ACCEPT_EVERY =
        2; // EMI takes one request per clkEMI (83MHz vs 133MHz)

    struct Beat {
        uint32_t data[4];
        uint64_t ready;
    };

    std::vector<uint8_t> mem = std::vector<uint8_t>(1u << 28);
    std::deque<Beat> beats;
    uint64_t last_ready = 0, next_accept = 0;
    uint64_t reads = 0, writes = 0;

    // same format $readmemh took: whitespace separated hex bytes, @addr jumps, // comments
    bool load(const char *path) {
        std::ifstream f(path);
        if (!f) {
            fprintf(stderr, "fake EMI: can't open %s\n", path);
            return false;
        }
        std::string tok;
        uint32_t addr = 0;
        while (f >> tok) {
            if (tok.rfind("//", 0) == 0) {
                std::getline(f, tok);
            } else if (tok[0] == '@') {
                addr = std::stoul(tok.substr(1), nullptr, 16);
            } else if (addr < mem.size()) {
                mem[addr++] = std::stoul(tok, nullptr, 16);
            }
        }
        return true;
    }

    // call after the clk=0 eval, right before the rising edge
    void before_edge(VCORE &top, uint64_t cyc) {
        // one beat per cycle max, in the order the reads were accepted
        top.EMI_mem_done = !beats.empty() && beats.front().ready <= cyc;
        if (top.EMI_mem_done) {
            for (int w = 0; w < 4; w++) {
                top.EMI_rdata[w] = beats.front().data[w];
            }
            beats.pop_front();
        }

        top.EMI_req_awck = top.EMI_req && cyc >= next_accept;
        if (!top.EMI_req_awck) {
            return;
        }
        next_accept = cyc + ACCEPT_EVERY;
        uint32_t base = (top.EMI_req_addr * 16) & (mem.size() - 1);
        if (top.EMI_req_we) { // lands now, no mem_done, like the real EMI
            for (int b = 0; b < 16; b++) {
                if (!(top.EMI_req_msk >> b & 1)) { // msk 1 = byte masked out (DM)
                    mem[base + b] = top.EMI_req_wd[b / 4] >> 8 * (b % 4);
                }
            }
            writes++;
        } else { // data taken now, so it's in order with writes; byte i at [8i+7:8i]
            Beat beat;
            for (int w = 0; w < 4; w++) {
                beat.data[w] = mem[base + 4 * w] | mem[base + 4 * w + 1] << 8 |
                               mem[base + 4 * w + 2] << 16 | (uint32_t)mem[base + 4 * w + 3] << 24;
            }
            last_ready = std::max(cyc + LATENCY, last_ready + 1);
            beat.ready = last_ready;
            beats.push_back(beat);
            reads++;
        }
    }

    // what the CPU would load from addr: the D-cache's copy if the line is in there (it may be
    // dirty), otherwise ddr3. Doesn't see the victim buffer, a just-evicted box can show stale
    uint8_t peek(VCORE &top, uint32_t addr) {
        auto *r = top.rootp;
        uint32_t row = addr >> 4 & 0x7FF, idx = row >> 1, k = addr & 15;
        uint64_t lane[4];
        if (row & 1) {
            lane[0] = r->CORE__DOT__cache__DOT__data_cache__DOT__D_cacheO0[idx];
            lane[1] = r->CORE__DOT__cache__DOT__data_cache__DOT__D_cacheO1[idx];
            lane[2] = r->CORE__DOT__cache__DOT__data_cache__DOT__D_cacheO2[idx];
            lane[3] = r->CORE__DOT__cache__DOT__data_cache__DOT__D_cacheO3[idx];
        } else {
            lane[0] = r->CORE__DOT__cache__DOT__data_cache__DOT__D_cacheE0[idx];
            lane[1] = r->CORE__DOT__cache__DOT__data_cache__DOT__D_cacheE1[idx];
            lane[2] = r->CORE__DOT__cache__DOT__data_cache__DOT__D_cacheE2[idx];
            lane[3] = r->CORE__DOT__cache__DOT__data_cache__DOT__D_cacheE3[idx];
        }
        // meta bit j sits at 36*(j/4) + 9*(j%4) + 8; tag[12-j] for j<13, valid is j=15
        auto meta = [&](int j) { return lane[j / 4] >> (9 * (j % 4) + 8) & 1; };
        uint32_t tag = 0;
        for (int j = 0; j < 13; j++) {
            tag = tag << 1 | meta(j);
        }
        if (meta(15) && tag == (addr >> 15 & 0x1FFF)) {
            return lane[k / 4] >> 9 * (k % 4) & 0xFF;
        }
        return mem[addr & (mem.size() - 1)];
    }
};
