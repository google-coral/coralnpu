// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include <cstdint>

// Base address of the DMA CSR block on the core-local fabric.
#define CORALNPU_DMA_BASE 0x00032000u

// Register offsets
#define DMA_CTRL      0x00
#define DMA_STATUS    0x04
#define DMA_SRC_ADDR  0x08
#define DMA_DST_ADDR  0x0c
#define DMA_LEN_FLAGS 0x10
#define DMA_XFER_CFG  0x14
#define DMA_AREA_SIZE 0x18

#define CTRL_ENABLE      (1u << 0)
#define CTRL_START       (1u << 1)
#define CTRL_CLEAR_ERROR (1u << 3)
#define STATUS_DONE      (1u << 1)
#define STATUS_ERROR     (1u << 2)

constexpr uint32_t kPollLimit = 20000;

volatile uint8_t src[256]
    __attribute__((section(".extdata"), aligned(16)));  // >= len rounded up to n_areas*16 (Req 6)
volatile uint8_t dst[256 + 16]
    __attribute__((section(".data"), aligned(16)));  // n_areas*row_pitch (Req 7) + 16-byte canary

struct DmaStridedTestCfg {
  uint32_t len;
  uint32_t n_areas;
  uint32_t xfer_width;
  uint32_t area_size;
};

volatile DmaStridedTestCfg cfg __attribute__((section(".data"), aligned(16))) = {};

struct DmaStridedTestResults {
  uint32_t status;
  uint32_t timed_out;
  uint32_t dst_addr;
  uint32_t src_addr;
  uint32_t src_corrupted;
  uint32_t faulted;
  uint32_t mcause;
  uint32_t mtval;
};

volatile DmaStridedTestResults results __attribute__((section(".data"))) = {};

extern "C" {
void coralnpu_exception_handler() {
  results.faulted = 1;
  uint32_t local_mcause;
  asm volatile("csrr %0, mcause" : "=r"(local_mcause));
  results.mcause = local_mcause;
  uint32_t local_mtval;
  asm volatile("csrr %0, mtval" : "=r"(local_mtval));
  results.mtval = local_mtval;

  asm volatile("ebreak");
  while (1) {
  }
}
}

static inline void dma_wr(uint32_t off, uint32_t v) {
  *(volatile uint32_t *)(CORALNPU_DMA_BASE + off) = v;
}

static inline uint32_t dma_rd(uint32_t off) {
  return *(volatile uint32_t *)(CORALNPU_DMA_BASE + off);
}

static inline void fence(void) { asm volatile("fence" ::: "memory"); }

int main() {
  for (uint32_t i = 0; i < sizeof(src); ++i) {
    src[i] = (uint8_t)(i * 37 + 11);
  }

  if (dma_rd(DMA_STATUS) & STATUS_ERROR) {
    dma_wr(DMA_CTRL, CTRL_CLEAR_ERROR);
  }

  fence();
  dma_wr(DMA_SRC_ADDR, (uint32_t)(uintptr_t)src);
  dma_wr(DMA_DST_ADDR, (uint32_t)(uintptr_t)dst);
  dma_wr(DMA_LEN_FLAGS, cfg.len | (cfg.xfer_width << 24));
  dma_wr(DMA_XFER_CFG, cfg.n_areas);
  dma_wr(DMA_AREA_SIZE, cfg.area_size);
  dma_wr(DMA_CTRL, CTRL_ENABLE | CTRL_START);

  uint32_t status    = 0;
  uint32_t timed_out = 1;
  for (uint32_t n = 0; n < kPollLimit; ++n) {
    status = dma_rd(DMA_STATUS);
    if (status & (STATUS_DONE | STATUS_ERROR)) {
      timed_out = 0;
      break;
    }
  }

  fence();
  uint32_t src_corrupted = 0;
  if (!timed_out) {
    for (uint32_t i = 0; i < sizeof(src); ++i) {
      if (src[i] != (uint8_t)(i * 37 + 11)) {
        ++src_corrupted;
      }
    }
  }

  results.status        = status;
  results.timed_out     = timed_out;
  results.dst_addr      = (uint32_t)(uintptr_t)dst;
  results.src_addr      = (uint32_t)(uintptr_t)src;
  results.src_corrupted = src_corrupted;

  return 0;
}
