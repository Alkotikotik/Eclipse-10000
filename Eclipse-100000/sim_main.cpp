#include "VCORE.h"
#include "VCORE___024root.h"
#include "verilated.h"
#include <SDL2/SDL.h>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <iostream>
#include <memory>
#include <vector>

constexpr int INTERNAL_WIDTH = 640;
constexpr int INTERNAL_HEIGHT = 480;
constexpr uint32_t VRAM_SIZE = INTERNAL_WIDTH * INTERNAL_HEIGHT * 2; // RGBA4444

constexpr int WINDOW_WIDTH = 1920;
constexpr int WINDOW_HEIGHT = 1080;

constexpr int SIM_BATCH_CYCLES = 50000;

static std::vector<uint8_t> vram_buffer(1024 * 1024, 0);

static volatile std::sig_atomic_t g_stop = 0;
void handle_sigint(int) { g_stop = 1; }
uint8_t sdl_scancode_to_charset(SDL_Scancode sc);

// CPI counter
static uint64_t g_total_cycles = 0;
static uint64_t g_retired_instructions = 0;
static uint64_t g_cond_branches = 0;
static uint64_t g_branch_mispredicts = 0;

static inline double current_cpi() {
    return g_retired_instructions
               ? static_cast<double>(g_total_cycles) / static_cast<double>(g_retired_instructions)
               : 0.0;
}

static inline double current_mispredict_pct() {
    return g_cond_branches ? 100.0 * static_cast<double>(g_branch_mispredicts) /
                                 static_cast<double>(g_cond_branches)
                           : 0.0;
}

int main(int argc, char **argv) {
    std::signal(SIGINT, handle_sigint);
    bool shift_held = false;

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

    Verilated::commandArgs(argc, argv);
    auto top = std::make_unique<VCORE>();

    // Reset sequence
    top->reset = 1;
    top->clk = 0;
    top->eval();
    top->ENC_10K_KeyIn = 0xFF;

    for (int i = 0; i < 4; i++) {
        top->clk = !top->clk;
        top->eval();
    }
    top->reset = 0;

    auto last_frame_time = std::chrono::steady_clock::now();
    auto last_mhz_report = std::chrono::steady_clock::now();

    SDL_Event event;
    uint64_t cycles_last_second = 0;
    int frames_last_second = 0;
    bool vram_dirty = true;

    while (!g_stop && !Verilated::gotFinish()) {

        for (int b = 0; b < SIM_BATCH_CYCLES; ++b) {
            top->clk = 0;
            top->eval();

            top->ENC_10K_ModArr = shift_held ? 1 : 0;

            top->clk = 1;
            top->eval();

            if (top->vram_write) [[unlikely]] {
                uint32_t addr = top->vram_addr;
                uint32_t data = top->vram_data_out;

                if (addr < vram_buffer.size() - 3) {
                    *reinterpret_cast<uint32_t *>(&vram_buffer[addr]) = data;
                    vram_dirty = true;
                }
            }

            //== CPI sampling, right after the posedge settles ==//
            g_total_cycles++;
            if (top->rootp->CORE__DOT__isWB_valid) {
                g_retired_instructions++;
            }
            if (top->rootp->CORE__DOT__isEX_valid && top->rootp->CORE__DOT__is_EX_cond_branch) {
                g_cond_branches++;
                bool predicted_taken = top->rootp->CORE__DOT__EX_predicted_taken;
                bool actually_taken = top->rootp->CORE__DOT__was_branch_taken;
                if (predicted_taken != actually_taken) {
                    g_branch_mispredicts++;
                }
            }

            cycles_last_second++;
        }

        auto now = std::chrono::steady_clock::now();

        if (std::chrono::duration_cast<std::chrono::milliseconds>(now - last_frame_time).count() >=
            16) {
            last_frame_time = now;
            frames_last_second++;

            while (SDL_PollEvent(&event)) {
                if (event.type == SDL_QUIT) {
                    g_stop = 1;
                } else if (event.type == SDL_KEYDOWN && !event.key.repeat) {
                    if (event.key.keysym.scancode == SDL_SCANCODE_LSHIFT ||
                        event.key.keysym.scancode == SDL_SCANCODE_RSHIFT) {
                        shift_held = true;
                    } else {
                        top->ENC_10K_KeyIn = sdl_scancode_to_charset(event.key.keysym.scancode);
                    }
                } else if (event.type == SDL_KEYUP) {
                    if (event.key.keysym.scancode == SDL_SCANCODE_LSHIFT ||
                        event.key.keysym.scancode == SDL_SCANCODE_RSHIFT) {
                        shift_held = false;
                    } else {
                        top->ENC_10K_KeyIn = 0xFF;
                    }
                }
            }

            if (vram_dirty) {
                void *pixels;
                int pitch;
                SDL_LockTexture(texture, NULL, &pixels, &pitch);
                memcpy(pixels, vram_buffer.data(), VRAM_SIZE);
                SDL_UnlockTexture(texture);
                vram_dirty = false;
            }

            SDL_RenderClear(renderer);
            SDL_RenderCopy(renderer, texture, NULL, NULL);
            SDL_RenderPresent(renderer);
        }

        if (std::chrono::duration_cast<std::chrono::seconds>(now - last_mhz_report).count() >= 1) {
            double mhz = static_cast<double>(cycles_last_second) / 1'000'000.0;
            std::cout << "[PERF] Speed: " << mhz << " MHz | Rendering: " << frames_last_second
                      << " FPS | CPI: " << current_cpi()
                      << " | Branch mispredict: " << current_mispredict_pct() << "%" << std::endl;

            cycles_last_second = 0;
            frames_last_second = 0;
            last_mhz_report = now;
        }
    }

    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();

    std::cout << "\n--- PERFORMANCE SUMMARY ---" << std::endl;
    std::cout << "Total cycles:          " << g_total_cycles << std::endl;
    std::cout << "Retired instructions:  " << g_retired_instructions << std::endl;
    std::cout << "CPI:                   " << current_cpi() << std::endl;
    std::cout << "Conditional branches:  " << g_cond_branches << std::endl;
    std::cout << "Mispredicts:           " << g_branch_mispredicts << " ("
              << current_mispredict_pct() << "%)" << std::endl;

    std::cout << "\n--- VRAM DUMP ---" << std::endl;
    for (uint32_t vram_offset = 0; vram_offset <= 0x2000; vram_offset += 4) {
        uint32_t bus_addr = 0x04000000 + vram_offset;
        uint32_t word = vram_buffer[vram_offset + 0] | (vram_buffer[vram_offset + 1] << 8) |
                        (vram_buffer[vram_offset + 2] << 16) | (vram_buffer[vram_offset + 3] << 24);

        std::cout << "Address [0x" << std::hex << bus_addr << "]: 0x" << std::hex << word << " ("
                  << std::dec << word << ")" << std::endl;
    }

    std::cout << "\n--- SYSTEM RAM DUMP HIGHER---" << std::endl;
    for (int addr = 0x03FFFFF0; addr >= 0x03FFFF00; addr -= 4) {
        uint32_t word = top->rootp->CORE__DOT__system_ram__DOT__ramm[addr] |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 1] << 8) |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 2] << 16) |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 3] << 24);

        std::cout << "Address [0x" << std::hex << addr << "]: 0x" << std::hex << word << " ("
                  << std::dec << word << ")" << std::endl;
    }

    std::cout << "\n--- SYSTEM RAM DUMP LOWER ---" << std::endl;
    for (int addr = 4096; addr >= 4000; addr -= 4) {
        uint32_t word = top->rootp->CORE__DOT__system_ram__DOT__ramm[addr] |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 1] << 8) |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 2] << 16) |
                        (top->rootp->CORE__DOT__system_ram__DOT__ramm[addr + 3] << 24);

        std::cout << "Address [" << std::dec << addr << "]: 0x" << std::hex << word << " ("
                  << std::dec << word << ")" << std::endl;
    }

    std::cout << "\n--- MMIO DUMP ---" << std::endl;
    for (uint32_t vram_offset = 0; vram_offset <= 0x10; vram_offset += 4) {
        uint32_t bus_addr = 0x04100000 + vram_offset;
        uint32_t word = vram_buffer[vram_offset + 0] | (vram_buffer[vram_offset + 1] << 8) |
                        (vram_buffer[vram_offset + 2] << 16) | (vram_buffer[vram_offset + 3] << 24);

        std::cout << "Address [0x" << std::hex << bus_addr << "]: 0x" << word << " (" << std::dec
                  << word << ")" << std::endl;
    }

    return 0;
}

#include <SDL2/SDL.h>
#include <cstdint>

uint8_t sdl_scancode_to_charset(SDL_Scancode sc) {
    switch (sc) {
    // Digits (0 - 9)
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

    // Space (10)
    case SDL_SCANCODE_SPACE:
        return 10;

    // Uppercase Letters (11 - 36)
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
    // Exclamation Mark (63)
    case SDL_SCANCODE_KP_EXCLAM:
        return 63;

    default:
        return 0xFF; // Filler
    }
}
