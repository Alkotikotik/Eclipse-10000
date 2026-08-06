#include "VCORE.h"
#include "VCORE___024root.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <SDL2/SDL.h>
#include <chrono>
#include <csignal>
#include <iostream>
#include <memory>
#include <thread>
#include <vector>

constexpr int INTERNAL_WIDTH = 640;
constexpr int INTERNAL_HEIGHT = 480;
constexpr uint32_t VRAM_SIZE = INTERNAL_WIDTH * INTERNAL_HEIGHT * 2; // RGBA4444

// 1080p: 1920 x 1080
// 1440p: 2560 x 1440
constexpr int WINDOW_WIDTH = 1920;
constexpr int WINDOW_HEIGHT = 1080;

constexpr double TARGET_CPU_HZ = 10000000.0; // 10 MHz seems pretty fast

static std::vector<uint8_t> vram_buffer(1024 * 1024, 0);

static volatile std::sig_atomic_t g_stop = 0;
void handle_sigint(int) { g_stop = 1; }

int main(int argc, char **argv) {
    std::signal(SIGINT, handle_sigint);

    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        std::cerr << "SDL Initialization failed: " << SDL_GetError() << std::endl;
        return -1;
    }

    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");

    SDL_Window *window = SDL_CreateWindow(
        "Custom ISA - 480p VRAM Monitor (Upscaled)", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
        WINDOW_WIDTH, WINDOW_HEIGHT, SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);

    SDL_Renderer *renderer =
        SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED | SDL_RENDERER_PRESENTVSYNC);

    SDL_Texture *texture =
        SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA4444, SDL_TEXTUREACCESS_STREAMING,
                          INTERNAL_WIDTH, INTERNAL_HEIGHT);

    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);
    auto tfp = std::make_unique<VerilatedVcdC>();
    auto top = std::make_unique<VCORE>();
    top->trace(tfp.get(), 99);
    tfp->open("waveform.vcd");

    top->reset = 1;
    top->clk = 0;
    top->eval();
    tfp->dump(0);

    uint64_t sim_time = 0;
    for (int i = 0; i < 4; i++) {
        sim_time++;
        top->clk = !top->clk;
        top->eval();
        tfp->dump(sim_time);
    }
    top->reset = 0;
    std::cout << "Beginning execution — Ctrl+C or close window to stop..." << std::endl;

    auto last_frame_time = std::chrono::steady_clock::now();

    const auto cycle_period = (TARGET_CPU_HZ > 0.0)
                                  ? std::chrono::duration<double>(1.0 / TARGET_CPU_HZ / 2.0)
                                  : std::chrono::duration<double>(0);
    auto next_tick = std::chrono::steady_clock::now();

    SDL_Event event;

    while (!g_stop && !Verilated::gotFinish()) {
        sim_time++;
        top->clk = !top->clk;
        top->eval();

        if (top->clk == 1 && top->vram_write) {
            uint32_t addr = top->vram_addr;
            uint32_t data = top->vram_data_out;

            if (addr < vram_buffer.size() - 3) {
                vram_buffer[addr + 0] = static_cast<uint8_t>(data & 0xFF);
                vram_buffer[addr + 1] = static_cast<uint8_t>((data >> 8) & 0xFF);
                vram_buffer[addr + 2] = static_cast<uint8_t>((data >> 16) & 0xFF);
                vram_buffer[addr + 3] = static_cast<uint8_t>((data >> 24) & 0xFF);
            }
        }

        tfp->dump(sim_time);

        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::milliseconds>(now - last_frame_time).count() >=
            16) {
            last_frame_time = now;

            while (SDL_PollEvent(&event)) {
                if (event.type == SDL_QUIT) {
                    g_stop = 1;
                }
            }

            void *pixels;
            int pitch;
            SDL_LockTexture(texture, NULL, &pixels, &pitch);
            memcpy(pixels, vram_buffer.data(), VRAM_SIZE);
            SDL_UnlockTexture(texture);

            SDL_RenderClear(renderer);
            SDL_RenderCopy(renderer, texture, NULL, NULL);
            SDL_RenderPresent(renderer);
        }

        if (TARGET_CPU_HZ > 0.0) {
            next_tick +=
                std::chrono::duration_cast<std::chrono::steady_clock::duration>(cycle_period);
            std::this_thread::sleep_until(next_tick);
        }
    }

    tfp->close();
    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();

    std::cout << "\nSimulation stopped. Waveform saved to 'waveform.vcd'" << std::endl;

    std::cout << "\n--- VRAM DUMP (First 5 Words) ---" << std::endl;
    for (uint32_t vram_offset = 0; vram_offset <= 0x10; vram_offset += 4) {
        uint32_t bus_addr = 0x04000000 + vram_offset;
        uint32_t word = vram_buffer[vram_offset + 0] | (vram_buffer[vram_offset + 1] << 8) |
                        (vram_buffer[vram_offset + 2] << 16) | (vram_buffer[vram_offset + 3] << 24);

        std::cout << "Address [0x" << std::hex << bus_addr << "]: 0x" << std::hex << word << " ("
                  << std::dec << word << ")" << std::endl;
    }

    std::cout << "\n--- SYSTEM RAM DUMP ---" << std::endl;
    for (int addr = 0x03FFFFF0; addr >= 0x03FFFF00; addr -= 4) {
        uint32_t word = top->rootp->CORE__DOT__system_ram__DOT__ramm[addr] |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 1] << 8) |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 2] << 16) |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 3] << 24);

        std::cout << "Address [0x" << std::hex << addr << "]: 0x" << std::hex << word << " ("
                  << std::dec << word << ")" << std::endl;
    }

    return 0;
}
