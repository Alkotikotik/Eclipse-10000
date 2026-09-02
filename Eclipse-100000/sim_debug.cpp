#include "VCORE.h"
#include "VCORE___024root.h"
#include "verilated.h"
#include "verilated_fst_c.h"
#include <SDL2/SDL.h>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <vector>

constexpr int INTERNAL_WIDTH = 640;
constexpr int INTERNAL_HEIGHT = 480;
constexpr uint32_t VRAM_SIZE = INTERNAL_WIDTH * INTERNAL_HEIGHT * 2; // RGBA4444

constexpr int WINDOW_WIDTH = 1920;
constexpr int WINDOW_HEIGHT = 1080;


static volatile std::sig_atomic_t g_stop = 0;
void handle_sigint(int) { g_stop = 1; }

// Function prototype
uint8_t sdl_scancode_to_charset(SDL_Scancode sc);

int main(int argc, char **argv) {
    std::signal(SIGINT, handle_sigint);

    // --- SDL Initialization ---
    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        std::cerr << "SDL Initialization failed: " << SDL_GetError() << std::endl;
        return -1;
    }

    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");

    SDL_Window *window =
        SDL_CreateWindow("Eclipse-10000 Monitor", SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                         WINDOW_WIDTH, WINDOW_HEIGHT, SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);

    SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    SDL_Texture *texture =
        SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA4444, SDL_TEXTUREACCESS_STREAMING,
                          INTERNAL_WIDTH, INTERNAL_HEIGHT);

    // --- Verilator & Tracing Setup ---
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    auto top = std::make_unique<VCORE>();

    // VRAM lives in the RTL now, point straight at it instead of
    // mirroring writes, that way byte enables are honoured for free
    uint8_t *vram_buffer = &top->rootp->CORE__DOT__system_vram__DOT__vramm[0];
    auto tfp = std::make_unique<VerilatedFstC>();

    top->trace(tfp.get(), 99);
    tfp->open("waveform.fst"); // Compressed FST format

    uint64_t sim_time = 0;

    // --- Reset Sequence ---
    top->reset = 1;
    top->clk = 0;
    top->ENC_10K_KeyIn = 0xFF;
    top->eval();
    tfp->dump(sim_time);

    for (int i = 0; i < 4; i++) {
        sim_time++;
        top->clk = !top->clk;
        top->eval();
        tfp->dump(sim_time);
    }
    top->reset = 0;

    std::cout << "Beginning execution at 1 kHz — Ctrl+C or Close window to stop...\n";

    // --- Rate Control Parameters (1 kHz = 1000 full cycles/sec) ---
    const double target_hz = 1000.0;
    const auto half_period = std::chrono::duration<double>(1.0 / target_hz / 2.0);
    auto next_tick = std::chrono::steady_clock::now();

    auto last_frame_time = std::chrono::steady_clock::now();
    SDL_Event event;
    bool vram_dirty = true;

    // --- Main Simulation Loop ---
    while (!g_stop && !Verilated::gotFinish()) {
        // Toggle clock state (Half Cycle)
        sim_time++;
        top->clk = !top->clk;
        top->eval();
        tfp->dump(sim_time);

        // Active edge logging & VRAM update
        if (top->clk == 1) {
            // Print ID stage PC / IR
            std::cout << "[Cycle " << (sim_time / 2) << "] "
                      << "ID_PC=0x" << std::hex << (uint32_t)top->rootp->CORE__DOT__ID_PC
                      << " ID_IR=0x" << std::hex << (uint32_t)top->rootp->CORE__DOT__ID_IR
                      << std::dec << std::endl;

            // Capture VRAM writes
            if (top->vram_write) [[unlikely]] {
                vram_dirty = true;
            }
        }

        // --- Render Frame (~60 FPS polling rate) ---
        auto now = std::chrono::steady_clock::now();
        if (std::chrono::duration_cast<std::chrono::milliseconds>(now - last_frame_time).count() >=
            16) {
            last_frame_time = now;

            while (SDL_PollEvent(&event)) {
                if (event.type == SDL_QUIT) {
                    g_stop = 1;
                } else if (event.type == SDL_KEYDOWN && !event.key.repeat) {
                    top->ENC_10K_KeyIn = sdl_scancode_to_charset(event.key.keysym.scancode);
                } else if (event.type == SDL_KEYUP) {
                    top->ENC_10K_KeyIn = 0xFF;
                }
            }

            if (vram_dirty) {
                void *pixels;
                int pitch;
                SDL_LockTexture(texture, NULL, &pixels, &pitch);
                std::memcpy(pixels, vram_buffer, VRAM_SIZE);
                SDL_UnlockTexture(texture);
                vram_dirty = false;
            }

            SDL_RenderClear(renderer);
            SDL_RenderCopy(renderer, texture, NULL, NULL);
            SDL_RenderPresent(renderer);
        }

        // Maintain strict 1 kHz rate
        next_tick += std::chrono::duration_cast<std::chrono::steady_clock::duration>(half_period);
        std::this_thread::sleep_until(next_tick);
    }

    // --- Cleanup Waveform and Display ---
    tfp->close();
    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();

    std::cout << "\nSimulation stopped. Waveform saved to 'waveform.fst'" << std::endl;

    // --- VRAM DUMP ---
    std::cout << "\n--- VRAM DUMP ---" << std::endl;
    for (uint32_t vram_offset = 0; vram_offset <= 0x2000; vram_offset += 4) {
        uint32_t bus_addr = 0x04000000 + vram_offset;
        uint32_t word = vram_buffer[vram_offset + 0] | (vram_buffer[vram_offset + 1] << 8) |
                        (vram_buffer[vram_offset + 2] << 16) | (vram_buffer[vram_offset + 3] << 24);

        std::cout << "Address [0x" << std::hex << bus_addr << "]: 0x" << word << " (" << std::dec
                  << word << ")" << std::endl;
    }

    std::cout << "\n--- MMIO DUMP ---" << std::endl;
    for (uint32_t vram_offset = 0; vram_offset <= 0x10; vram_offset += 4) {
        uint32_t bus_addr = 0x04100000 + vram_offset;
        uint32_t word = vram_buffer[vram_offset + 0] | (vram_buffer[vram_offset + 1] << 8) |
                        (vram_buffer[vram_offset + 2] << 16) | (vram_buffer[vram_offset + 3] << 24);

        std::cout << "Address [0x" << std::hex << bus_addr << "]: 0x" << word << " (" << std::dec
                  << word << ")" << std::endl;
    }

    // --- SYSTEM RAM DUMP HIGHER ---
    std::cout << "\n--- SYSTEM RAM DUMP HIGHER ---" << std::endl;
    for (int addr = 0x03FFFFF0; addr >= 0x03FFFF00; addr -= 4) {
        uint32_t word = top->rootp->CORE__DOT__system_ram__DOT__ramm[addr] |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 1] << 8) |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 2] << 16) |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 3] << 24);

        std::cout << "Address [0x" << std::hex << addr << "]: 0x" << word << " (" << std::dec
                  << word << ")" << std::endl;
    }

    // --- SYSTEM RAM DUMP LOWER ---
    std::cout << "\n--- SYSTEM RAM DUMP LOWER ---" << std::endl;
    for (int addr = 4096; addr >= 4000; addr -= 4) {
        uint32_t word = top->rootp->CORE__DOT__system_ram__DOT__ramm[addr] |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 1] << 8) |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 2] << 16) |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 3] << 24);

        std::cout << "Address [" << std::dec << addr << "]: 0x" << std::hex << word << " ("
                  << std::dec << word << ")" << std::endl;
    }

    return 0;
}

// --- Keyboard Translation Definition ---
uint8_t sdl_scancode_to_charset(SDL_Scancode sc) {
    switch (sc) {
    case SDL_SCANCODE_0:
        return 0;
    case SDL_SCANCODE_1:
        return 1;
    case SDL_SCANCODE_2:
        return 2;
    case SDL_SCANCODE_3:
        return 3;
    case SDL_SCANCODE_4:
        return 4;
    case SDL_SCANCODE_5:
        return 5;
    case SDL_SCANCODE_6:
        return 6;
    case SDL_SCANCODE_7:
        return 7;
    case SDL_SCANCODE_8:
        return 8;
    case SDL_SCANCODE_9:
        return 9;
    case SDL_SCANCODE_SPACE:
        return 10;
    case SDL_SCANCODE_A:
        return 11;
    case SDL_SCANCODE_B:
        return 12;
    case SDL_SCANCODE_C:
        return 13;
    case SDL_SCANCODE_D:
        return 14;
    case SDL_SCANCODE_E:
        return 15;
    case SDL_SCANCODE_F:
        return 16;
    case SDL_SCANCODE_G:
        return 17;
    case SDL_SCANCODE_H:
        return 18;
    case SDL_SCANCODE_I:
        return 19;
    case SDL_SCANCODE_J:
        return 20;
    case SDL_SCANCODE_K:
        return 21;
    case SDL_SCANCODE_L:
        return 22;
    case SDL_SCANCODE_M:
        return 23;
    case SDL_SCANCODE_N:
        return 24;
    case SDL_SCANCODE_O:
        return 25;
    case SDL_SCANCODE_P:
        return 26;
    case SDL_SCANCODE_Q:
        return 27;
    case SDL_SCANCODE_R:
        return 28;
    case SDL_SCANCODE_S:
        return 29;
    case SDL_SCANCODE_T:
        return 30;
    case SDL_SCANCODE_U:
        return 31;
    case SDL_SCANCODE_V:
        return 32;
    case SDL_SCANCODE_W:
        return 33;
    case SDL_SCANCODE_X:
        return 34;
    case SDL_SCANCODE_Y:
        return 35;
    case SDL_SCANCODE_Z:
        return 36;
    case SDL_SCANCODE_KP_EXCLAM:
        return 63;
    default:
        return 0xFF;
    }
}
