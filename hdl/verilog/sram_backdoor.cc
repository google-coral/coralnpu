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

#include "sram_backdoor.h"

#include <elf.h>

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <map>
#include <random>
#include <vector>

#include "svdpi.h"

namespace coralnpu {
namespace {

struct BackdoorSram {
  std::vector<uint8_t> data;
  uint64_t global_addr;
  uint32_t width_bytes;
};

std::map<uint64_t, BackdoorSram *> registered_srams;

bool ApplyLoadToSram(BackdoorSram &sram, uint64_t load_addr,
                     const uint8_t *data, size_t len) {
  uint64_t load_end = load_addr + len;
  uint64_t sram_end = sram.global_addr + sram.data.size();

  if (load_end <= sram.global_addr || load_addr >= sram_end) {
    return false;
  }

  uint64_t start = std::max(load_addr, sram.global_addr);
  uint64_t end = std::min(load_end, sram_end);
  uint64_t copy_len = end - start;
  uint64_t sram_offset = start - sram.global_addr;
  uint64_t data_offset = start - load_addr;

  std::memcpy(sram.data.data() + sram_offset, data + data_offset, copy_len);
  return true;
}

void *RegisterSram(uint64_t global_addr, size_t size_bytes,
                   uint32_t width_bytes) {
  BackdoorSram *sram = new BackdoorSram;
  sram->global_addr = global_addr;
  sram->data.resize(size_bytes);
  sram->width_bytes = width_bytes;

  // Randomize memory content for simulation.
  std::random_device rd;
  std::mt19937 gen(rd());
  std::uniform_int_distribution<> dis(0, 255);
  for (size_t i = 0; i < size_bytes; ++i) {
    sram->data[i] = dis(gen);
  }

  registered_srams[global_addr] = sram;

  return sram;
}

} // namespace

bool SramBackdoorLoad(uint64_t global_addr, const uint8_t *data, size_t len) {
  bool load_ok = false;
  // Sweep all SRAMs, until we find the correct one or exhaust our options.
  for (const auto &[base, sram] : registered_srams) {
    if (ApplyLoadToSram(*sram, global_addr, data, len)) {
      load_ok = true;
    }
  }
  return load_ok;
}

template <typename Ehdr, typename Phdr>
bool LoadElfSegmentsTyped(FILE *f, const char *filename) {
  Ehdr ehdr;
  if (std::fread(&ehdr, sizeof(ehdr), 1, f) != 1) {
    std::fprintf(stderr, "[SRAM Backdoor] Failed to read ELF header: %s\n", filename);
    return false;
  }

  if (std::fseek(f, ehdr.e_phoff, SEEK_SET) != 0) {
    std::fprintf(stderr, "[SRAM Backdoor] Failed to seek to program headers: %s\n", filename);
    return false;
  }

  std::vector<Phdr> phdrs(ehdr.e_phnum);
  if (std::fread(phdrs.data(), sizeof(Phdr), ehdr.e_phnum, f) != ehdr.e_phnum) {
    std::fprintf(stderr, "[SRAM Backdoor] Failed to read program headers: %s\n", filename);
    return false;
  }

  for (const auto &phdr : phdrs) {
    if (phdr.p_type != PT_LOAD || phdr.p_filesz == 0) {
      continue;
    }

    std::vector<uint8_t> buffer(phdr.p_filesz);
    if (std::fseek(f, phdr.p_offset, SEEK_SET) != 0) {
      std::fprintf(stderr, "[SRAM Backdoor] Failed to seek to segment data: %s\n", filename);
      return false;
    }

    if (std::fread(buffer.data(), 1, phdr.p_filesz, f) != phdr.p_filesz) {
      std::fprintf(stderr, "[SRAM Backdoor] Failed to read segment data: %s\n", filename);
      return false;
    }

    SramBackdoorLoad(phdr.p_paddr, buffer.data(), buffer.size());
  }

  return true;
}

} // namespace coralnpu

extern "C" {
using namespace coralnpu;

void *sram_init(uint64_t global_addr, uint64_t size_bytes,
                uint32_t width_bytes) {
  return RegisterSram(global_addr, size_bytes, width_bytes);
}

void sram_read(void *handle, uint32_t addr, svBitVecVal *data) {
  BackdoorSram *sram = static_cast<BackdoorSram *>(handle);
  size_t offset = (size_t)addr * sram->width_bytes;
  if (offset + sram->width_bytes <= sram->data.size()) {
    std::memcpy(data, sram->data.data() + offset, sram->width_bytes);
  }
}

void sram_write(void *handle, uint32_t addr, const svBitVecVal *data,
                uint32_t wmask) {
  BackdoorSram *sram = static_cast<BackdoorSram *>(handle);
  size_t offset = (size_t)addr * sram->width_bytes;
  if (offset + sram->width_bytes <= sram->data.size()) {
    uint8_t *dest = sram->data.data() + offset;
    const uint8_t *src = reinterpret_cast<const uint8_t *>(data);
    for (size_t i = 0; i < sram->width_bytes; ++i) {
      if (i < 32 && ((wmask >> i) & 1)) {
        dest[i] = src[i];
      }
    }
  }
}

void sram_cleanup(void *handle) {
  if (!handle)
    return;
  BackdoorSram *sram = static_cast<BackdoorSram *>(handle);
  registered_srams.erase(sram->global_addr);
  delete sram;
}

void sram_clear() {
  for (auto const& [base, sram] : registered_srams) {
    std::fill(sram->data.begin(), sram->data.end(), 0);
  }
}

bool sram_backdoor_load_c(uint64_t global_addr, const uint8_t *data,
                          size_t len) {
  return SramBackdoorLoad(global_addr, data, len);
}

void sram_load_elf(const char *filename) {
  FILE *f = std::fopen(filename, "rb");
  if (!f) {
    std::fprintf(stderr, "[SRAM Backdoor] Failed to open ELF file: %s\n", filename);
    return;
  }

  unsigned char e_ident[EI_NIDENT];
  if (std::fread(e_ident, 1, EI_NIDENT, f) != EI_NIDENT) {
    std::fprintf(stderr, "[SRAM Backdoor] Failed to read ELF magic: %s\n", filename);
    std::fclose(f);
    return;
  }

  if (std::memcmp(e_ident, ELFMAG, SELFMAG) != 0) {
    std::fprintf(stderr, "[SRAM Backdoor] Invalid ELF magic: %s\n", filename);
    std::fclose(f);
    return;
  }

  const unsigned char elf_class = e_ident[EI_CLASS];
  if (elf_class != ELFCLASS32 && elf_class != ELFCLASS64) {
    std::fprintf(stderr, "[SRAM Backdoor] Unsupported ELF class %u: %s\n", elf_class, filename);
    std::fclose(f);
    return;
  }

  if (std::fseek(f, 0, SEEK_SET) != 0) {
    std::fprintf(stderr, "[SRAM Backdoor] Failed to rewind ELF file: %s\n", filename);
    std::fclose(f);
    return;
  }

  if (elf_class == ELFCLASS64) {
    LoadElfSegmentsTyped<Elf64_Ehdr, Elf64_Phdr>(f, filename);
  } else {
    LoadElfSegmentsTyped<Elf32_Ehdr, Elf32_Phdr>(f, filename);
  }

  std::fclose(f);
}
}
