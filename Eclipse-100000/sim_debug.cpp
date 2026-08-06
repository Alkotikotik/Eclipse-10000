#include "VCORE.h"
#include "VCORE___024root.h"
#include "verilated.h"
#include "verilated_fst_c.h" // Modern, compressed binary format
#include <SDL2/SDL.h>
#include <chrono>
#include <csignal>
#include <iostream>
#include <memory>
#include <vector>

constexpr int INTERNAL_WIDTH = 640;
constexpr int INTERNAL_HEIGHT = 480;
constexpr uint32_t VRAM_SIZE = INTERNAL_WIDTH * INTERNAL_HEIGHT * 2;

constexpr int WINDOW_WIDTH = 1280;
constexpr int WINDOW_HEIGHT = 720;

// Maximum dump window length (50,000 cycles = ~10-20 MB in FST format)
constexpr uint64_t MAX_DEBUG_CYCLES = 50000;

static std::vector<uint8_t> vram_buffer(1024 * 1024, 0);

static volatile std::sig_atomic_t g_stop = 0;
void handle_sigint(int) { g_stop = 1; }

int main(int argc, char **argv) {
    std::signal(SIGINT, handle_sigint);

    if (SDL_Init(SDL_INIT_VIDEO) < 0) {
        std::cerr << "SDL Initialization failed: " << SDL_GetError() << std::endl;
        return -1;
    }

    SDL_Window *window = SDL_CreateWindow("Custom ISA - Debug Mode (Press 'T' to Toggle Tracing)",
                                          SDL_WINDOWPOS_CENTERED, SDL_WINDOWPOS_CENTERED,
                                          WINDOW_WIDTH, WINDOW_HEIGHT, SDL_WINDOW_SHOWN);

    SDL_Renderer *renderer = SDL_CreateRenderer(window, -1, SDL_RENDERER_ACCELERATED);
    SDL_Texture *texture =
        SDL_CreateTexture(renderer, SDL_PIXELFORMAT_RGBA4444, SDL_TEXTUREACCESS_STREAMING,
                          INTERNAL_WIDTH, INTERNAL_HEIGHT);

    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    auto top = std::make_unique<VCORE>();
    auto tfp = std::make_unique<VerilatedFstC>();

    top->trace(tfp.get(), 99); // Dump depth
    tfp->open("waveform.fst");

    // Reset sequence
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

    bool tracing_active = true;
    uint64_t traced_cycles = 0;

    std::cout << "[DEBUG MODE] Simulation started." << std::endl;
    std::cout << "  -> Waveform recording to 'waveform.fst'" << std::endl;
    std::cout << "  -> Press 'T' in SDL window to manually pause/resume waveform tracing."
              << std::endl;

    SDL_Event event;

    while (!g_stop && !Verilated::gotFinish()) {

        // Check key events each cycle in debug mode
        while (SDL_PollEvent(&event)) {
            if (event.type == SDL_QUIT) {
                g_stop = 1;
            } else if (event.type == SDL_KEYDOWN) {
                if (event.key.keysym.sym == SDLK_t) {
                    tracing_active = !tracing_active;
                    std::cout << "[DEBUG] Tracing " << (tracing_active ? "ENABLED" : "PAUSED")
                              << std::endl;
                }
            }
        }

        // Low Clock
        sim_time++;
        top->clk = 0;
        top->eval();
        if (tracing_active && traced_cycles < MAX_DEBUG_CYCLES) {
            tfp->dump(sim_time);
        }

        // High Clock
        sim_time++;
        top->clk = 1;
        top->eval();
        if (tracing_active && traced_cycles < MAX_DEBUG_CYCLES) {
            tfp->dump(sim_time);
            traced_cycles++;

            if (traced_cycles == MAX_DEBUG_CYCLES) {
                std::cout << "[SAFETY] MAX_DEBUG_CYCLES reached (" << MAX_DEBUG_CYCLES
                          << "). Tracing automatically paused to save disk space." << std::endl;
                tracing_active = false;
            }
        }

        if (top->vram_write) {
            uint32_t addr = top->vram_addr;
            uint32_t data = top->vram_data_out;
            if (addr < vram_buffer.size() - 3) {
                *reinterpret_cast<uint32_t *>(&vram_buffer[addr]) = data;
            }
        }

        // UI Refresh
        void *pixels;
        int pitch;
        SDL_LockTexture(texture, NULL, &pixels, &pitch);
        memcpy(pixels, vram_buffer.data(), VRAM_SIZE);
        SDL_UnlockTexture(texture);

        SDL_RenderClear(renderer);
        SDL_RenderCopy(renderer, texture, NULL, NULL);
        SDL_RenderPresent(renderer);
    }

    tfp->flush();
    tfp->close();

    SDL_DestroyTexture(texture);
    SDL_DestroyRenderer(renderer);
    SDL_DestroyWindow(window);
    SDL_Quit();

    std::cout << "\n[DEBUG] Finished. Waveform successfully written to 'waveform.fst'."
              << std::endl;
    return 0;
}
