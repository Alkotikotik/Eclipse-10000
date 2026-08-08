#include "VCORE.h"
#include "VCORE___024root.h"
#include "verilated.h"
#include <SDL2/SDL.h>
#include <chrono>
#include <csignal>
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

int main(int argc, char **argv) {
    std::signal(SIGINT, handle_sigint);

    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        std::cerr << "SDL Initialization failed: " << SDL_GetError() << std::endl;
        return -1;
    }

    SDL_SetHint(SDL_HINT_RENDER_SCALE_QUALITY, "0");

    SDL_Window *window = SDL_CreateWindow("Custom ISA - High Speed Monitor", SDL_WINDOWPOS_CENTERED,
                                          SDL_WINDOWPOS_CENTERED, WINDOW_WIDTH, WINDOW_HEIGHT,
                                          SDL_WINDOW_SHOWN | SDL_WINDOW_RESIZABLE);

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
                      << " FPS" << std::endl;

            cycles_last_second = 0;
            frames_last_second = 0;
            last_mhz_report = now;
        }
    }

    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();

    std::cout << "\n--- VRAM DUMP (First 5 Words) ---" << std::endl;
    for (uint32_t vram_offset = 0; vram_offset <= 0xF00; vram_offset += 4) {
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
