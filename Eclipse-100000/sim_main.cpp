#include "VCORE.h"
#include "VCORE___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h" // Include the waveform tracing header
#include <iostream>
#include <memory>

uint64_t sim_time = 0;

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);

    // 1. Enable tracing capabilities
    Verilated::traceEverOn(true);
    auto tfp = std::make_unique<VerilatedVcdC>();

    auto top = std::make_unique<VCORE>();

    // 2. Open the dump file
    top->trace(tfp.get(), 99); // Trace 99 levels of hierarchy deep
    tfp->open("waveform.vcd");

    // Assert Reset
    top->reset = 1;
    top->clk = 0;
    top->eval();
    tfp->dump(sim_time); // Dump initial state to waveform

    for (int i = 0; i < 4; i++) {
        sim_time++;
        top->clk = !top->clk;
        top->eval();
        tfp->dump(sim_time); // Dump state on every toggle
    }

    // De-assert Reset
    top->reset = 0;
    std::cout << "Beginning execution with waveform tracing..." << std::endl;

    // Main Simulation Loop
    while (sim_time < 2000 && !Verilated::gotFinish()) {
        sim_time++;
        top->clk = !top->clk;
        top->eval();
        tfp->dump(sim_time); // Log the signal changes to the VCD file

        if (top->clk == 1) {
            std::cout << "[Cycle " << (sim_time / 2) << "]"
                      << " PC = 0x" << std::hex << (int)top->rootp->CORE__DOT__PC << " | IR = 0x"
                      << std::hex << (int)top->rootp->CORE__DOT__IR << std::endl;
        }
    }

    // 3. Flush and close the waveform file cleanly
    tfp->close();
    std::cout << "Simulation finished. Waveform saved to 'waveform.vcd'" << std::endl;
    return 0;
}
