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

#ifndef SW_CORALNPU_SIM_SPIKE_SIMULATOR_H_
#define SW_CORALNPU_SIM_SPIKE_SIMULATOR_H_

#include <cstddef>
#include <cstdint>
#include <memory>
#include <optional>
#include <string>
#include <vector>

namespace coralnpu::sim {

struct SpikeMemoryRegion {
  uint64_t start_address = 0;
  size_t length          = 0;
};

struct SpikeSimulatorOptions {
  std::string isa =
      "rv32imf_zve32f_zvl128b_zicsr_zifencei_zbb_zfbfmin_zvfbfmin_zvfbfwma_zvfbfa_xdummy";
  std::string priv = "m";
  bool misaligned  = true;
  std::vector<SpikeMemoryRegion> memory_regions;
};

class SpikeSimulator {
 public:
  explicit SpikeSimulator(const SpikeSimulatorOptions &options = {});
  ~SpikeSimulator();

  // Program loading & control
  bool LoadProgram(const std::string &elf_path, std::optional<uint32_t> entry_point = std::nullopt);
  int Step(int num_steps);
  void Reset();
  bool IsHalted() const;

  // Register access
  uint64_t ReadRegister(const std::string &name);
  void WriteRegister(const std::string &name, uint64_t value);
  bool ReadVectorRegister(int v_idx, uint32_t words[4]);
  bool WriteVectorRegister(int v_idx, const uint32_t words[4]);

  // Memory access
  bool ReadMemory(uint64_t address, void *buffer, size_t length);
  bool WriteMemory(uint64_t address, const void *buffer, size_t length);
  void WriteWord(uint64_t address, uint32_t data);
  void WritePtr(uint64_t address, uint64_t ptr_address);

  // Status
  uint64_t GetPC() const;
  uint64_t GetCycleCount() const;

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};

}  // namespace coralnpu::sim

#endif  // SW_CORALNPU_SIM_SPIKE_SIMULATOR_H_
