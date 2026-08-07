#include "VCORE.h"
#include "VCORE___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <chrono>
#include <csignal>
#include <iostream>
#include <memory>
#include <thread>

static volatile std::sig_atomic_t g_stop = 0;
void handle_sigint(int) { g_stop = 1; }

uint64_t sim_time = 0;

int main(int argc, char **argv) {
    std::signal(SIGINT, handle_sigint);

    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    auto tfp = std::make_unique<VerilatedVcdC>();
    auto top = std::make_unique<VCORE>();
    top->trace(tfp.get(), 99);
    tfp->open("waveform.vcd");

    top->reset = 1;
    top->clk = 0;
    top->eval();
    tfp->dump(sim_time);

    for (int i = 0; i < 4; i++) {
        sim_time++;
        top->clk = !top->clk;
        top->eval();
        tfp->dump(sim_time);
    }

    top->reset = 0;
    std::cout << "Beginning execution — Ctrl+C to stop..." << std::endl;

    // Target rate: full clock cycles per second (2 toggles per cycle).
    const double target_hz = 1000.0;
    const auto period = std::chrono::duration<double>(1.0 / target_hz / 2.0);
    auto next_tick = std::chrono::steady_clock::now();

    while (!g_stop && !Verilated::gotFinish()) {
        sim_time++;
        top->clk = !top->clk;
        top->eval();
        tfp->dump(sim_time);

        if (top->clk == 1) {
            std::cout << "[Cycle " << (sim_time / 2) << "]"
                      << " PC = 0x" << std::hex << (int)top->rootp->CORE__DOT__PC << " | IR = 0x"
                      << std::hex << (int)top->rootp->CORE__DOT__IR << std::endl;
        }

        next_tick += std::chrono::duration_cast<std::chrono::steady_clock::duration>(period);
        std::this_thread::sleep_until(next_tick);
    }

    tfp->close();
    std::cout << "\nSimulation stopped (" << (g_stop ? "Ctrl+C" : "finish()")
              << "). Waveform saved to 'waveform.vcd'" << std::endl;

    std::cout << "\n--- RAM DUMP (32-bit Words) ---" << std::endl;
    for (int addr = 4000; addr <= 4096; addr += 4) {
        uint32_t word = top->rootp->CORE__DOT__system_ram__DOT__ramm[addr] |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 1] << 8) |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 2] << 16) |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 3] << 24);

        std::cout << "Address [" << std::dec << addr << "]: 0x" << std::hex << word << " ("
                  << std::dec << word << ")" << std::endl;
    }

    return 0;
}
