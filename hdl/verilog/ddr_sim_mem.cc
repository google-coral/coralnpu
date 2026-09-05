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

#include "ddr_sim_mem.h"

#include <cstdio>
#include <cstring>
#include <vector>

#include "svdpi.h"

namespace {

struct DdrSimMem {
  uint64_t base = 0;
  std::vector<uint8_t> mem;  // empty until configured
};

DdrSimMem g_ddr;

constexpr uint64_t kLineBytes = 16;

inline bool InWindow(uint64_t addr, uint64_t len) {
  return !g_ddr.mem.empty() && addr >= g_ddr.base &&
         addr + len <= g_ddr.base + g_ddr.mem.size();
}

}  // namespace

extern "C" {

void ddr_backdoor_configure_c(uint64_t base, uint64_t size) {
  g_ddr.base = base;
  g_ddr.mem.assign(size, 0);
  std::fprintf(stderr, "[ddr_sim_mem] configured base=0x%llx size=%llu (store %p)\n",
               (unsigned long long)base, (unsigned long long)size, (void*)&g_ddr);
}

bool ddr_backdoor_write_c(uint64_t addr, const uint8_t* data, size_t len) {
  if (!InWindow(addr, len)) return false;
  std::memcpy(g_ddr.mem.data() + (addr - g_ddr.base), data, len);
  return true;
}

bool ddr_backdoor_read_c(uint64_t addr, uint8_t* data, size_t len) {
  if (!InWindow(addr, len)) return false;
  std::memcpy(data, g_ddr.mem.data() + (addr - g_ddr.base), len);
  return true;
}

uint64_t ddr_backdoor_base_c() { return g_ddr.base; }
uint64_t ddr_backdoor_size_c() { return g_ddr.mem.size(); }

// DPI: returns the 16-byte line containing addr. data[0] holds bits 31:0
// (byte lane 0 in the low byte), matching AXI byte-lane numbering on a
// little-endian bus.
int ddr_sim_read(unsigned long long addr, svBitVecVal* data) {
  uint64_t line = addr & ~(kLineBytes - 1);
  if (!InWindow(line, kLineBytes)) {
    std::fprintf(stderr, "[ddr_sim_mem] read miss addr=0x%llx base=0x%llx size=%llu (store %p)\n",
                 (unsigned long long)addr, (unsigned long long)g_ddr.base,
                 (unsigned long long)g_ddr.mem.size(), (void*)&g_ddr);
    std::memset(data, 0, kLineBytes);
    return 1;
  }
  std::memcpy(data, g_ddr.mem.data() + (line - g_ddr.base), kLineBytes);
  return 0;
}

int ddr_sim_write(unsigned long long addr, const svBitVecVal* data,
                  const svBitVecVal* strb) {
  uint64_t line = addr & ~(kLineBytes - 1);
  if (!InWindow(line, kLineBytes)) return 1;
  const uint8_t* src = reinterpret_cast<const uint8_t*>(data);
  uint8_t* dst = g_ddr.mem.data() + (line - g_ddr.base);
  uint32_t mask = strb[0] & 0xFFFF;
  for (uint64_t i = 0; i < kLineBytes; ++i) {
    if (mask & (1u << i)) dst[i] = src[i];
  }
  return 0;
}

}  // extern "C"
