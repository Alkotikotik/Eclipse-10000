#include "VALU.h"
#include "verilated.h"
#include <iostream>
#include <memory>

int main(int argc, char **argv) {
  const std::unique_ptr<VerilatedContext> contextp{new VerilatedContext};
  contextp->commandArgs(argc, argv);

  const std::unique_ptr<VALU> top{new VALU{contextp.get()}};

  std::cout << "--- Starting ALU Simulation ---" << std::endl;

  top->x = 10;
  top->y = 20;
  top->eval();
  std::cout << "Test 1: " << (int)top->x << " + " << (int)top->y << " = "
            << (int)top->result << std::endl;

  top->x = 0xFFFFFFF0;
  top->y = 0xF;
  top->eval();
  std::cout << "Test 2: " << top->x << " + " << top->y << " = " << top->result
            << std::endl;

  std::cout << "--- Simulation Finished ---" << std::endl;
  return 0;
}
