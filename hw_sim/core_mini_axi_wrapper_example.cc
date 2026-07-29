// Copyright 2025 Google LLC
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

#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include <cstdint>
#include <iostream>
#
#include "hw_sim/core_mini_axi_wrapper.h"
#include "tests/verilator_sim/elf.h"

int main() {
  VerilatedContext context;
  CoreMiniAxiWrapper wrapper(&context);
  wrapper.Reset();

  // Load elf
  auto file_name = "tests/cocotb/wfi_slot_0.elf";
  int fd = open(file_name, 0);
  if (fd < 0) {
    return -1;
  }
  struct stat sb;
  if (fstat(fd, &sb) != 0) {
    close(fd);
    return -1;
  }
  auto file_size = sb.st_size;
  auto file_data = mmap(nullptr, file_size, PROT_READ, MAP_PRIVATE, fd, 0);
  CopyFn copy_fn = [&wrapper](void* dest, const void* src , size_t count) {
    uint32_t addr = static_cast<uint32_t>(reinterpret_cast<uint64_t>(dest));
    wrapper.Write(addr, count, reinterpret_cast<const char*>(src));
    return dest;
  };
  uint32_t start_pc = LoadElf(reinterpret_cast<uint8_t*>(file_data), copy_fn);

  munmap(file_data, file_size);
  close(fd);

  std::cout << "Loaded " << file_name << std::endl;

  // Start Program
  wrapper.WriteWord(0x30004, start_pc);
  wrapper.WriteWord(0x30000, 1u);
  wrapper.WriteWord(0x30000, 0u);

  // Wait for interrupt
  if (wrapper.WaitForTermination()) {
    std::cout << "Halted" << std::endl;
  } else {
    std::cout << "Didn't halt" << std::endl;
  }

  return 0;
}
