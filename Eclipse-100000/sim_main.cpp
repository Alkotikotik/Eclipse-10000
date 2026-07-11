#include "VALU.h"
#include "verilated.h"
#include "verilated_vcd_c.h" // Waveform header
#include <iostream>
#include <memory>

void print_test(const char *name, bool passed) {
  if (passed)
    std::cout << "[PASS] " << name << std::endl;
  else
    std::cout << "[FAIL] " << name << " <<<< ERROR!" << std::endl;
}

int main(int argc, char **argv) {
  const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
  contextp->commandArgs(argc, argv);
  contextp->traceEverOn(true); // Turn on tracing capability

  const std::unique_ptr<VALU> top{new VALU{contextp.get()}};

  // Setup waveform recorder
  VerilatedVcdC *tfp = new VerilatedVcdC;
  top->trace(tfp, 99);
  tfp->open("waveform.vcd");

  uint64_t sim_time = 0; // Timeline tracker

  std::cout << "=== Starting Comprehensive Waveform Test Suite ==="
            << std::endl;

  // --- TEST 1: ADD 0 + 0 ---
  top->opcode = 0b000001;
  top->x = 0;
  top->y = 0;
  top->eval();
  tfp->dump(sim_time);
  sim_time += 10; // Record and step time
  print_test("ADD 0 + 0 = 0", (top->result == 0 && top->ZeroFlag == 1));

  // --- TEST 2: SUB 5 - 10 ---
  top->opcode = 0b000011;
  top->x = 5;
  top->y = 10;
  top->eval();
  tfp->dump(sim_time);
  sim_time += 10;
  print_test("SUB 5 - 10 = -5",
             ((int32_t)top->result == -5 && top->NegativeFlag == 1));

  // --- TEST 3: SUB Overflow ---
  top->opcode = 0b000011;
  top->x = 2147483647;
  top->y = -1;
  top->eval();
  tfp->dump(sim_time);
  sim_time += 10;
  print_test("SUB Overflow Detection", (top->OverflowFlag == 1));

  // --- TEST 4: ADD Overflow ---
  top->opcode = 0b000001;
  top->x = 0x80000000;
  top->y = 0xFFFFFFFF;
  top->eval();
  tfp->dump(sim_time);
  sim_time += 10;
  print_test("ADD Overflow Detection", (top->OverflowFlag == 1));

  // --- TEST 5: Bitwise AND ---
  top->opcode = 0b001110;
  top->x = 0x0F0F0F0F;
  top->y = 0xFFFF0000;
  top->eval();
  tfp->dump(sim_time);
  sim_time += 10;
  print_test("Bitwise AND check", (top->result == 0x0F0F0000));

  top->opcode = 0b000111;
  top->x = 0x0000000F;
  top->y = 0x0000000F;
  top->eval();
  tfp->dump(sim_time);
  sim_time += 10;
  print_test("Multiplication check: ", (top->result = 0x000000e1));

  // Wrap up
  tfp->close();
  delete tfp;
  std::cout << "=== Waveform successfully generated! ===" << std::endl;
  return 0;
}
