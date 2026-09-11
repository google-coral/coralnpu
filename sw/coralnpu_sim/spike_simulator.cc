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

#include "sw/coralnpu_sim/spike_simulator.h"

#include <cstddef>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <memory>
#include <optional>
#include <string>
#include <unordered_map>
#include <vector>

#include "fesvr/elfloader.h"
#include "riscv/cfg.h"
#include "riscv/encoding.h"
#include "riscv/extension.h"
#include "riscv/mmu.h"
#include "riscv/processor.h"
#include "riscv/sim.h"

namespace coralnpu::sim {

namespace {

int ParseXprIndex(const std::string &name) {
  static const std::unordered_map<std::string, int> kAbiToIdx = {
      {"zero", 0}, {"ra", 1},  {"sp", 2},  {"gp", 3},  {"tp", 4},  {"t0", 5},  {"t1", 6},
      {"t2", 7},   {"s0", 8},  {"fp", 8},  {"s1", 9},  {"a0", 10}, {"a1", 11}, {"a2", 12},
      {"a3", 13},  {"a4", 14}, {"a5", 15}, {"a6", 16}, {"a7", 17}, {"s2", 18}, {"s3", 19},
      {"s4", 20},  {"s5", 21}, {"s6", 22}, {"s7", 23}, {"s8", 24}, {"s9", 25}, {"s10", 26},
      {"s11", 27}, {"t3", 28}, {"t4", 29}, {"t5", 30}, {"t6", 31},
  };

  auto it = kAbiToIdx.find(name);
  if (it != kAbiToIdx.end()) {
    return it->second;
  }

  if (name.size() > 1 && (name[0] == 'x' || name[0] == 'X')) {
    try {
      size_t pos = 0;
      int idx    = std::stoi(name.substr(1), &pos);
      if (pos == name.size() - 1 && idx >= 0 && idx < 32)
        return idx;
    } catch (...) {
    }
  }

  return -1;
}

int ParseFprIndex(const std::string &name) {
  static const std::unordered_map<std::string, int> kFabiToIdx = {
      {"ft0", 0},  {"ft1", 1},  {"ft2", 2},   {"ft3", 3},   {"ft4", 4},  {"ft5", 5},   {"ft6", 6},
      {"ft7", 7},  {"fs0", 8},  {"fs1", 9},   {"fa0", 10},  {"fa1", 11}, {"fa2", 12},  {"fa3", 13},
      {"fa4", 14}, {"fa5", 15}, {"fa6", 16},  {"fa7", 17},  {"fs2", 18}, {"fs3", 19},  {"fs4", 20},
      {"fs5", 21}, {"fs6", 22}, {"fs7", 23},  {"fs8", 24},  {"fs9", 25}, {"fs10", 26}, {"fs11", 27},
      {"ft8", 28}, {"ft9", 29}, {"ft10", 30}, {"ft11", 31},
  };

  auto it = kFabiToIdx.find(name);
  if (it != kFabiToIdx.end()) {
    return it->second;
  }

  if (name.size() > 1 && (name[0] == 'f' || name[0] == 'F')) {
    try {
      size_t pos = 0;
      int idx    = std::stoi(name.substr(1), &pos);
      if (pos == name.size() - 1 && idx >= 0 && idx < 32)
        return idx;
    } catch (...) {
    }
  }

  return -1;
}

int ParseVprIndex(const std::string &name) {
  if (name.size() > 1 && (name[0] == 'v' || name[0] == 'V')) {
    try {
      size_t pos = 0;
      int idx    = std::stoi(name.substr(1), &pos);
      if (pos == name.size() - 1 && idx >= 0 && idx < 32)
        return idx;
    } catch (...) {
    }
  }
  return -1;
}

int ParseCsrIndex(const std::string &name) {
  static const std::unordered_map<std::string, int> kCsrMap = {
      {"fflags", 0x001}, {"frm", 0x002},      {"fcsr", 0x003},    {"mstatus", 0x300},
      {"misa", 0x301},   {"mie", 0x304},      {"mtvec", 0x305},   {"mscratch", 0x340},
      {"mepc", 0x341},   {"mcause", 0x342},   {"mtval", 0x343},   {"mip", 0x344},
      {"mcycle", 0xB00}, {"minstret", 0xB02}, {"mcycleh", 0xB80}, {"minstreth", 0xB82},
      {"cycle", 0xC00},  {"time", 0xC01},     {"instret", 0xC02}, {"cycleh", 0xC80},
      {"timeh", 0xC81},  {"instreth", 0xC82}, {"vstart", 0x008},  {"vxsat", 0x009},
      {"vxrm", 0x00A},   {"vcsr", 0x00F},     {"vl", 0xC20},      {"vtype", 0xC21},
      {"vlenb", 0xC22},
  };

  auto it = kCsrMap.find(name);
  if (it != kCsrMap.end()) {
    return it->second;
  }

  // Hex or decimal CSR number
  if (!name.empty()) {
    try {
      size_t pos = 0;
      int val    = std::stoi(name, &pos, 0);
      if (pos == name.size() && val >= 0 && val < 4096)
        return val;
    } catch (...) {
    }
  }

  return -1;
}

static reg_t SafeMpauseHandler(processor_t *p, insn_t insn, reg_t pc) {
  p->get_state()->debug_mode = true;
  return pc + 4;
}

}  // namespace

struct SpikeSimulator::Impl {
  std::string isa_str;
  std::string priv_str;
  cfg_t cfg;
  std::vector<std::unique_ptr<abstract_mem_t>> mem_storage;
  std::vector<std::pair<reg_t, abstract_mem_t *>> mems;
  std::unique_ptr<sim_t> sim;
  processor_t *proc   = nullptr;
  uint64_t step_count = 0;

  explicit Impl(const SpikeSimulatorOptions &options) {
    isa_str              = options.isa;
    priv_str             = options.priv;
    cfg.isa              = isa_str.c_str();
    cfg.priv             = priv_str.c_str();
    cfg.misaligned       = options.misaligned;
    cfg.hartids          = {0};
    cfg.explicit_hartids = true;
    cfg.pmpregions       = 16;
    cfg.pmpgranularity   = 4;

    cfg.mem_layout.clear();
    if (options.memory_regions.empty()) {
      // Default CoralNPU V2 memory map (matching memory_map_pkg.sv and SPIKE_MEMORY_REGIONS):
      // ITCM: 0x00000000, 8KB (0x2000)
      // DTCM: 0x00010000, 32KB (0x8000)
      // Extmem: 0x20000000, 4MB (0x400000)
      cfg.mem_layout.push_back(mem_cfg_t(0x00000000, 0x00002000));
      cfg.mem_layout.push_back(mem_cfg_t(0x00010000, 0x00008000));
      cfg.mem_layout.push_back(mem_cfg_t(0x20000000, 0x00400000));
    } else {
      for (const auto &r : options.memory_regions) {
        cfg.mem_layout.push_back(mem_cfg_t(r.start_address, r.length));
      }
    }

    for (const auto &r : cfg.mem_layout) {
      auto mem = std::make_unique<mem_t>(r.get_size());
      mems.push_back({r.get_base(), mem.get()});
      mem_storage.push_back(std::move(mem));
    }

    std::vector<device_factory_sargs_t> plugin_devices;
    std::vector<std::string> htif_args = {"spike"};
    debug_module_config_t dm_config;

    sim = std::make_unique<sim_t>(&cfg,
                                  /*halted=*/false, mems, plugin_devices, htif_args, dm_config,
                                  /*log_path=*/nullptr,
                                  /*dtb_enabled=*/false,
                                  /*dtb_file=*/nullptr,
                                  /*socket_enabled=*/false,
                                  /*cmd_file=*/nullptr,
                                  /*instruction_limit=*/std::nullopt);

    proc = sim->get_core(0);

    // Override mpause to avoid process exit(0)
    insn_desc_t mpause_desc = {
        MATCH_MPAUSE,       MASK_MPAUSE,        &SafeMpauseHandler, &SafeMpauseHandler,
        &SafeMpauseHandler, &SafeMpauseHandler, &SafeMpauseHandler, &SafeMpauseHandler,
        &SafeMpauseHandler, &SafeMpauseHandler,
    };
    proc->register_custom_insn(mpause_desc);
    proc->build_opcode_map();

    // Configure ebreak to enter debug mode instead of calling exit(0)
    proc->get_state()->dcsr->ebreakm  = true;
    proc->get_state()->dcsr->ebreaks  = true;
    proc->get_state()->dcsr->ebreaku  = true;
    proc->get_state()->dcsr->ebreakvs = true;
    proc->get_state()->dcsr->ebreakvu = true;

    // Enable vector ALU execution with non-zero vstart
    proc->VU.vstart_alu = true;
  }

  ~Impl() {
    sim.reset();
    mem_storage.clear();
    mems.clear();
  }
};

SpikeSimulator::SpikeSimulator(const SpikeSimulatorOptions &options)
    : impl_(std::make_unique<Impl>(options)) {}

SpikeSimulator::~SpikeSimulator() = default;

void SpikeSimulator::Reset() {
  if (impl_->proc) {
    impl_->proc->reset();
    impl_->proc->get_state()->dcsr->ebreakm  = true;
    impl_->proc->get_state()->dcsr->ebreaks  = true;
    impl_->proc->get_state()->dcsr->ebreaku  = true;
    impl_->proc->get_state()->dcsr->ebreakvs = true;
    impl_->proc->get_state()->dcsr->ebreakvu = true;
    impl_->proc->VU.vstart_alu               = true;
  }
  impl_->step_count = 0;
}

bool SpikeSimulator::IsHalted() const {
  if (!impl_->proc)
    return true;
  return impl_->proc->get_state()->debug_mode;
}

bool SpikeSimulator::LoadProgram(const std::string &elf_path, std::optional<uint32_t> entry_point) {
  reg_t entry = 0;
  try {
    load_elf(elf_path.c_str(), &impl_->sim->memif(), &entry, /*load_offset=*/0,
             /*required_xlen=*/32);
  } catch (const std::exception &e) {
    std::cerr << "Failed to load ELF " << elf_path << ": " << e.what() << std::endl;
    return false;
  }

  if (entry_point.has_value()) {
    entry = entry_point.value();
  }
  if (impl_->proc) {
    impl_->proc->get_state()->pc = entry;
  }
  return true;
}

int SpikeSimulator::Step(int num_steps) {
  if (num_steps <= 0 || !impl_->proc)
    return 0;
  if (impl_->proc->get_state()->debug_mode)
    return 0;
  int executed = 0;
  for (int i = 0; i < num_steps; ++i) {
    impl_->proc->step(1);
    impl_->step_count++;
    executed++;
    if (impl_->proc->get_state()->debug_mode)
      break;
  }
  return executed;
}

uint64_t SpikeSimulator::GetPC() const {
  if (!impl_->proc)
    return 0;
  return impl_->proc->get_state()->pc & 0xFFFFFFFFULL;
}

uint64_t SpikeSimulator::GetCycleCount() const { return impl_->step_count; }

uint64_t SpikeSimulator::ReadRegister(const std::string &name) {
  if (!impl_->proc)
    return 0;

  if (name == "pc" || name == "PC") {
    return impl_->proc->get_state()->pc & 0xFFFFFFFFULL;
  }

  int x_idx = ParseXprIndex(name);
  if (x_idx >= 0 && x_idx < 32) {
    return impl_->proc->get_state()->XPR[x_idx] & 0xFFFFFFFFULL;
  }

  int f_idx = ParseFprIndex(name);
  if (f_idx >= 0 && f_idx < 32) {
    return impl_->proc->get_state()->FPR[f_idx].v[0] & 0xFFFFFFFFULL;
  }

  int v_idx = ParseVprIndex(name);
  if (v_idx >= 0 && v_idx < 32) {
    if (impl_->proc && impl_->proc->VU.reg_file) {
      return impl_->proc->VU.elt<uint32_t>(v_idx, 0);
    }
    return 0;
  }

  int csr_num = ParseCsrIndex(name);
  if (csr_num >= 0) {
    try {
      return impl_->proc->get_csr(csr_num) & 0xFFFFFFFFULL;
    } catch (const std::exception &e) {
      std::cerr << "Warning: get_csr failed for " << name << ": " << e.what() << std::endl;
      return 0;
    } catch (...) {
      std::cerr << "Warning: get_csr trap/exception for " << name << std::endl;
      return 0;
    }
  }

  std::cerr << "Warning: Unknown register name: " << name << std::endl;
  return 0;
}

void SpikeSimulator::WriteRegister(const std::string &name, uint64_t value) {
  if (!impl_->proc)
    return;

  if (name == "pc" || name == "PC") {
    impl_->proc->get_state()->pc = value;
    return;
  }

  int x_idx = ParseXprIndex(name);
  if (x_idx >= 0 && x_idx < 32) {
    if (x_idx > 0) {
      impl_->proc->get_state()->XPR.write(x_idx, value);
    }
    return;
  }

  int f_idx = ParseFprIndex(name);
  if (f_idx >= 0 && f_idx < 32) {
    freg_t fval = {value | 0xFFFFFFFF00000000ULL, 0};
    impl_->proc->get_state()->FPR.write(f_idx, fval);
    return;
  }

  int v_idx = ParseVprIndex(name);
  if (v_idx >= 0 && v_idx < 32) {
    if (impl_->proc && impl_->proc->VU.reg_file) {
      impl_->proc->VU.elt<uint32_t>(v_idx, 0, true) = static_cast<uint32_t>(value & 0xFFFFFFFFULL);
    }
    return;
  }

  int csr_num = ParseCsrIndex(name);
  if (csr_num >= 0) {
    try {
      if (csr_num == 0x344 || name == "mip") {
        impl_->proc->get_state()->mip->backdoor_write_with_mask(MIP_MEIP | MIP_MSIP | MIP_MTIP,
                                                                value);
      } else {
        impl_->proc->put_csr(csr_num, value);
      }
    } catch (const std::exception &e) {
      std::cerr << "Warning: put_csr failed for " << name << ": " << e.what() << std::endl;
    } catch (...) {
      std::cerr << "Warning: put_csr trap/exception for " << name << std::endl;
    }
    return;
  }

  std::cerr << "Warning: Unknown register name for write: " << name << std::endl;
}

bool SpikeSimulator::ReadVectorRegister(int v_idx, uint32_t words[4]) {
  if (!impl_->proc || v_idx < 0 || v_idx >= 32 || !impl_->proc->VU.reg_file) {
    return false;
  }
  for (int i = 0; i < 4; ++i) {
    words[i] = impl_->proc->VU.elt<uint32_t>(v_idx, i);
  }
  return true;
}

bool SpikeSimulator::WriteVectorRegister(int v_idx, const uint32_t words[4]) {
  if (!impl_->proc || v_idx < 0 || v_idx >= 32 || !impl_->proc->VU.reg_file) {
    return false;
  }
  for (int i = 0; i < 4; ++i) {
    impl_->proc->VU.elt<uint32_t>(v_idx, i, true) = words[i];
  }
  return true;
}

bool SpikeSimulator::ReadMemory(uint64_t address, void *buffer, size_t length) {
  if (!impl_->sim)
    return false;
  try {
    impl_->sim->memif().read(address, length, buffer);
    return true;
  } catch (const std::exception &e) {
    std::cerr << "ReadMemory failed at 0x" << std::hex << address << ": " << e.what() << std::endl;
    return false;
  }
}

bool SpikeSimulator::WriteMemory(uint64_t address, const void *buffer, size_t length) {
  if (!impl_->sim)
    return false;
  try {
    impl_->sim->memif().write(address, length, buffer);
    return true;
  } catch (const std::exception &e) {
    std::cerr << "WriteMemory failed at 0x" << std::hex << address << ": " << e.what() << std::endl;
    return false;
  }
}

void SpikeSimulator::WriteWord(uint64_t address, uint32_t data) { WriteMemory(address, &data, 4); }

void SpikeSimulator::WritePtr(uint64_t address, uint64_t ptr_address) {
  uint32_t val = static_cast<uint32_t>(ptr_address & 0xFFFFFFFFULL);
  WriteMemory(address, &val, 4);
}

}  // namespace coralnpu::sim
