// Copyright 2026 Google LLC
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

#include "sw/coralnpu_sim/spike_cosim_dpi.h"

#include <cstdint>
#include <iostream>
#include <memory>
#include <string>

#include "sw/coralnpu_sim/spike_simulator.h"

namespace {

std::unique_ptr<coralnpu::sim::SpikeSimulator> g_spike_sim = nullptr;

}  // namespace

extern "C" {

int spike_init() {
  if (g_spike_sim != nullptr) {
    g_spike_sim.reset();
  }
  try {
    g_spike_sim = std::make_unique<coralnpu::sim::SpikeSimulator>();
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "[Spike DPI] Initialization error: " << e.what() << std::endl;
    return -1;
  } catch (...) {
    std::cerr << "[Spike DPI] Unknown exception in spike_init." << std::endl;
    return -1;
  }
}

int spike_load_program(const char *elf_file, uint32_t entry_point, svBit has_entry_point) {
  try {
    if (g_spike_sim == nullptr) {
      if (spike_init() != 0)
        return -1;
    }
    if (elf_file == nullptr) {
      std::cerr << "[Spike DPI] Null elf_file pointer provided." << std::endl;
      return -1;
    }

    std::optional<uint32_t> entry = std::nullopt;
    if (has_entry_point) {
      entry = entry_point;
    }

    if (!g_spike_sim->LoadProgram(elf_file, entry)) {
      std::cerr << "[Spike DPI] Failed to load ELF program: " << elf_file << std::endl;
      return -1;
    }
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "[Spike DPI] Exception in spike_load_program: " << e.what() << std::endl;
    return -1;
  } catch (...) {
    std::cerr << "[Spike DPI] Unknown exception in spike_load_program." << std::endl;
    return -1;
  }
}

int spike_reset() {
  try {
    if (g_spike_sim == nullptr) {
      return spike_init();
    }
    g_spike_sim->Reset();
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "[Spike DPI] Exception in spike_reset: " << e.what() << std::endl;
    return -1;
  } catch (...) {
    std::cerr << "[Spike DPI] Unknown exception in spike_reset." << std::endl;
    return -1;
  }
}

int spike_step(uint32_t num_steps) {
  try {
    if (g_spike_sim == nullptr) {
      std::cerr << "[Spike DPI] Simulator not initialized before step." << std::endl;
      return -1;
    }
    if (num_steps == 0) {
      return 0;
    }
    int res = g_spike_sim->Step(num_steps);
    return (res > 0) ? 0 : -1;
  } catch (const std::exception &e) {
    std::cerr << "[Spike DPI] Exception in spike_step: " << e.what() << std::endl;
    return -1;
  } catch (...) {
    std::cerr << "[Spike DPI] Unknown exception in spike_step." << std::endl;
    return -1;
  }
}

svBit spike_is_halted() {
  try {
    if (g_spike_sim == nullptr)
      return 1;
    return g_spike_sim->IsHalted() ? 1 : 0;
  } catch (const std::exception &e) {
    std::cerr << "[Spike DPI] Exception in spike_is_halted: " << e.what() << std::endl;
    return 1;
  } catch (...) {
    std::cerr << "[Spike DPI] Unknown exception in spike_is_halted." << std::endl;
    return 1;
  }
}

int spike_get_register(const char *name, uint32_t *value) {
  try {
    if (value == nullptr || name == nullptr || g_spike_sim == nullptr)
      return -1;

    uint64_t reg_val = g_spike_sim->ReadRegister(name);
    *value           = static_cast<uint32_t>(reg_val & 0xFFFFFFFFULL);
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "[Spike DPI] Exception in spike_get_register: " << e.what() << std::endl;
    return -1;
  } catch (...) {
    std::cerr << "[Spike DPI] Unknown exception in spike_get_register." << std::endl;
    return -1;
  }
}

int spike_set_register(const char *name, uint32_t value) {
  try {
    if (name == nullptr || g_spike_sim == nullptr)
      return -1;

    g_spike_sim->WriteRegister(name, value);
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "[Spike DPI] Exception in spike_set_register: " << e.what() << std::endl;
    return -1;
  } catch (...) {
    std::cerr << "[Spike DPI] Unknown exception in spike_set_register." << std::endl;
    return -1;
  }
}

int spike_get_vector_register(const char *name, svLogicVecVal *value) {
  try {
    if (value == nullptr || name == nullptr || g_spike_sim == nullptr) {
      return -1;
    }

    int v_idx = -1;
    if (name[0] != '\0' && (name[0] == 'v' || name[0] == 'V') && name[1] != '\0') {
      try {
        size_t pos = 0;
        std::string s(name + 1);
        v_idx = std::stoi(s, &pos);
        if (pos != s.size()) {
          v_idx = -1;
        }
      } catch (...) {
        v_idx = -1;
      }
    }

    if (v_idx < 0 || v_idx >= 32) {
      std::cerr << "[Spike DPI] Invalid vector register name: " << name << std::endl;
      return -1;
    }

    uint32_t words[4] = {0};
    if (!g_spike_sim->ReadVectorRegister(v_idx, words)) {
      return -1;
    }

    for (int i = 0; i < 4; ++i) {
      value[i].aval = words[i];
      value[i].bval = 0;
    }
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "[Spike DPI] Exception in spike_get_vector_register: " << e.what() << std::endl;
    return -1;
  } catch (...) {
    std::cerr << "[Spike DPI] Unknown exception in spike_get_vector_register." << std::endl;
    return -1;
  }
}

int spike_apply_memory_patch(const char *patch_file) {
  try {
    if (g_spike_sim == nullptr) {
      std::cerr << "[Spike DPI] Simulator not initialized before apply patch." << std::endl;
      return -1;
    }
    if (patch_file == nullptr) {
      return 0;
    }
    FILE *f = std::fopen(patch_file, "rb");
    if (!f) {
      std::cerr << "[Spike DPI] Failed to open patch file: " << patch_file << std::endl;
      return -1;
    }

    while (true) {
      uint64_t addr = 0;
      uint32_t len  = 0;
      if (std::fread(&addr, sizeof(addr), 1, f) != 1) {
        break;  // Clean EOF
      }
      if (std::fread(&len, sizeof(len), 1, f) != 1) {
        std::cerr << "[Spike DPI] Truncated patch record length at 0x" << std::hex << addr
                  << std::endl;
        std::fclose(f);
        return -1;
      }
      if (len == 0) {
        continue;
      }

      std::vector<uint8_t> buffer(len);
      if (std::fread(buffer.data(), 1, len, f) != len) {
        std::cerr << "[Spike DPI] Truncated patch payload at 0x" << std::hex << addr << std::endl;
        std::fclose(f);
        return -1;
      }

      if (!g_spike_sim->WriteMemory(addr, buffer.data(), len)) {
        std::cerr << "[Spike DPI] WriteMemory failed at 0x" << std::hex << addr << " (" << std::dec
                  << len << " bytes)" << std::endl;
        std::fclose(f);
        return -1;
      }
    }

    std::fclose(f);
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "[Spike DPI] Exception in spike_apply_memory_patch: " << e.what() << std::endl;
    return -1;
  } catch (...) {
    std::cerr << "[Spike DPI] Unknown exception in spike_apply_memory_patch." << std::endl;
    return -1;
  }
}

int spike_fini() {
  try {
    g_spike_sim.reset();
    return 0;
  } catch (const std::exception &e) {
    std::cerr << "[Spike DPI] Exception in spike_fini: " << e.what() << std::endl;
    return -1;
  } catch (...) {
    std::cerr << "[Spike DPI] Unknown exception in spike_fini." << std::endl;
    return -1;
  }
}

}  // extern "C"
