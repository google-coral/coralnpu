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

#define CTRL_ENABLE      (1u << 0)
#define CTRL_START       (1u << 1)
#define CTRL_CLEAR_ERROR (1u << 3)
#define STATUS_DONE      (1u << 1)
#define STATUS_ERROR     (1u << 2)

constexpr uint32_t kBufBytes    = 64;
constexpr uint32_t kCanaryBytes = 16;
constexpr uint8_t kCanaryValue  = 0xA5;
constexpr uint32_t kPollLimit   = 20000;

// aligned(16) : (README Requirement 1)
static volatile uint8_t src[kBufBytes] __attribute__((section(".extdata"), aligned(16)));
// canary : (README Requirement 7)
static volatile uint8_t dst_and_canary[kBufBytes + kCanaryBytes] __attribute__((aligned(16)));
static volatile uint8_t *const dst    = dst_and_canary;
static volatile uint8_t *const canary = dst_and_canary + kBufBytes;

struct DmaMemcpyTestResults {
  uint32_t status;
  uint32_t mismatches;
  uint32_t first_bad_index;  // 0xFFFFFFFF when there is no mismatch.
  uint32_t dst_addr;
  uint32_t src_addr;
  uint32_t timed_out;
  uint32_t src_corrupted;
  uint32_t canary_bad;
  uint32_t faulted;
  uint32_t mcause;
  uint32_t mtval;
};

volatile DmaMemcpyTestResults results __attribute__((section(".data"))) = {};

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
  // 1. Fill src with a known pattern and clear dst.
  for (uint32_t i = 0; i < kBufBytes; ++i) {
    src[i] = (uint8_t)i;
    dst[i] = 0;
  }
  for (uint32_t i = 0; i < kCanaryBytes; ++i) {
    canary[i] = kCanaryValue;
  }

  // 2. Error bits are sticky; clear them so START is not ignored.
  if (dma_rd(DMA_STATUS) & STATUS_ERROR) {
    dma_wr(DMA_CTRL, CTRL_CLEAR_ERROR);
  }

  // 3. Make the buffer writes visible before the DMA reads memory, then
  //    program a memcopy and start it.
  fence();
  dma_wr(DMA_SRC_ADDR, (uint32_t)(uintptr_t)src);
  dma_wr(DMA_DST_ADDR, (uint32_t)(uintptr_t)dst);
  dma_wr(DMA_LEN_FLAGS, kBufBytes);  // xfer_width = 0, bits [31:27] = 0.
  dma_wr(DMA_XFER_CFG, 1);           // n_areas = 1: memcopy.
  dma_wr(DMA_CTRL, CTRL_ENABLE | CTRL_START);

  // 4. Poll until done or error.
  uint32_t status    = 0;
  uint32_t timed_out = 1;
  for (uint32_t n = 0; n < kPollLimit; ++n) {
    status = dma_rd(DMA_STATUS);
    if (status & (STATUS_DONE | STATUS_ERROR)) {
      timed_out = 0;
      break;
    }
  }

  uint32_t mismatches      = 0;
  uint32_t first_bad_index = 0xFFFFFFFFu;
  uint32_t src_corrupted   = 0;
  uint32_t canary_bad      = 0;
  if (!timed_out) {
    // 5. Order the DMA's writes before the CPU's reads, then compare.
    fence();
    for (uint32_t i = 0; i < kBufBytes; ++i) {
      if (dst[i] != (uint8_t)i) {
        if (mismatches == 0) {
          first_bad_index = i;
        }
        ++mismatches;
      }
      if (src[i] != (uint8_t)i) {
        ++src_corrupted;
      }
    }
    for (uint32_t i = 0; i < kCanaryBytes; ++i) {
      if (canary[i] != kCanaryValue) {
        ++canary_bad;
      }
    }
  }

  // 6. Publish results; returning from main halts the core.
  results.status          = status;
  results.mismatches      = mismatches;
  results.first_bad_index = first_bad_index;
  results.dst_addr        = (uint32_t)(uintptr_t)dst;
  results.src_addr        = (uint32_t)(uintptr_t)src;
  results.timed_out       = timed_out;
  results.src_corrupted   = src_corrupted;
  results.canary_bad      = canary_bad;

  return 0;
}
