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

#include <cassert>
#include <cstring>
#include <vector>

#include "hw_sim/coralnpu_simulator.h"
#include "hw_sim/core_mini_axi_wrapper.h"

namespace {

// The core's CSR block (CoreAxiCSR.scala): the status register (bit 0: halted,
// bit 1: fault) and the CSR values the core exports (io.csr.out.value in
// scalar/Csr.scala), one word each.
constexpr uint32_t kCoreCsrBase   = 0x30000;
constexpr uint32_t kCoreCsrStatus = kCoreCsrBase + 0x8;
constexpr uint32_t kCoreCsrValues = kCoreCsrBase + 0x100;
enum CoreCsrValue : uint32_t {
  kCoreCsrPc        = 0,
  kCoreCsrMepc      = 1,
  kCoreCsrMtval     = 2,
  kCoreCsrMcause    = 3,
  kCoreCsrMinstret  = 6,
  kCoreCsrMinstreth = 7,
};

// The number of cycles WaitForTermination waits if its timeout isn't positive.
constexpr int kDefaultTimeoutCycles = 10000;

}  // namespace

class CoreMiniAxiSimulator final : public CoralNPUSimulator {
 public:
  explicit CoreMiniAxiSimulator(const CoralNPUSimulatorOptions &options = {})
      : context_(), wrapper_(&context_, options) {
    ddr_memory_.resize(1024 * 1024 * 1024, 0);  // 1GB DDR
    auto read_cb = [this](const AxiAddr &axi_addr) { return this->ReadCallback(axi_addr); };
    wrapper_.RegisterReadCallback(read_cb);

    auto write_cb = [this](const AxiAddr &axi_addr, const AxiWData &axi_data) {
      return this->WriteCallback(axi_addr, axi_data);
    };
    wrapper_.RegisterWriteCallback(write_cb);

    wrapper_.Reset();
  }
  ~CoreMiniAxiSimulator() final = default;

  void ReadMem(uint32_t addr, size_t size, char *data) final;
  const CoralNPUMailbox &ReadMailbox(void) final;
  void WriteMem(uint32_t addr, size_t size, const char *data) final;
  void WriteMailbox(const CoralNPUMailbox &mailbox) final;
  void Run(uint32_t start_addr) final;
  bool WaitForTermination(int timeout) final;
  uint64_t GetCycleCount() const final;
  bool ReadCoreState(CoralNPUCoreState *state) final;

 private:
  VerilatedContext context_;
  CoreMiniAxiWrapper wrapper_;
  std::vector<uint8_t> ddr_memory_;

  bool IsDdrAddress(uint32_t addr) { return addr >= 0x80000000 && addr < 0xC0000000; }

  // Reads the word at |addr|.
  uint32_t ReadWord(uint32_t addr);
  // Reads CSR value |index| from the core's CSR block.
  uint32_t ReadCoreCsr(CoreCsrValue index) { return ReadWord(kCoreCsrValues + 4 * index); }

  AxiWResp WriteCallback(const AxiAddr &, const AxiWData &);
  AxiRData ReadCallback(const AxiAddr &);
};

void CoreMiniAxiSimulator::ReadMem(uint32_t addr, size_t size, char *data) {
  if (IsDdrAddress(addr)) {
    uint32_t offset = addr - 0x80000000;
    if (offset + size <= ddr_memory_.size()) {
      memcpy(data, ddr_memory_.data() + offset, size);
    } else {
      assert(false && "DDR read out of bounds");
    }
  } else {
    std::vector<uint8_t> read_result = wrapper_.Read(addr, size);
    memcpy(data, read_result.data(), size);
  }
}

const CoralNPUMailbox &CoreMiniAxiSimulator::ReadMailbox(void) { return wrapper_.ReadMailbox(); }

void CoreMiniAxiSimulator::WriteMem(uint32_t addr, size_t size, const char *data) {
  if (IsDdrAddress(addr)) {
    uint32_t offset = addr - 0x80000000;
    if (offset + size <= ddr_memory_.size()) {
      memcpy(ddr_memory_.data() + offset, data, size);
    } else {
      assert(false && "DDR write out of bounds");
    }
  } else {
    wrapper_.Write(addr, size, data);
  }
}

void CoreMiniAxiSimulator::WriteMailbox(const CoralNPUMailbox &mailbox) {
  wrapper_.WriteMailbox(mailbox);
}

void CoreMiniAxiSimulator::Run(uint32_t start_addr) {
  wrapper_.WriteWord(0x30004, start_addr);
  wrapper_.WriteWord(0x30000, 1u);
  wrapper_.WriteWord(0x30000, 0u);
}

bool CoreMiniAxiSimulator::WaitForTermination(int timeout) {
  return wrapper_.WaitForTermination(timeout > 0 ? timeout : kDefaultTimeoutCycles);
}

uint64_t CoreMiniAxiSimulator::GetCycleCount() const { return wrapper_.cycle_count(); }

uint32_t CoreMiniAxiSimulator::ReadWord(uint32_t addr) {
  uint32_t word = 0;
  ReadMem(addr, sizeof(word), reinterpret_cast<char *>(&word));
  return word;
}

bool CoreMiniAxiSimulator::ReadCoreState(CoralNPUCoreState *state) {
  // Word by word: the CSR block registers are one word wide.
  const uint32_t status = ReadWord(kCoreCsrStatus);
  state->halted         = (status & 1u) != 0;
  state->fault          = (status & 2u) != 0;
  state->pc             = ReadCoreCsr(kCoreCsrPc);
  state->mepc           = ReadCoreCsr(kCoreCsrMepc);
  state->mtval          = ReadCoreCsr(kCoreCsrMtval);
  state->mcause         = ReadCoreCsr(kCoreCsrMcause);
  // The core may still run (e.g. after a timeout), so read the counter as
  // high, low, high until the high word is stable.
  uint32_t high = ReadCoreCsr(kCoreCsrMinstreth);
  uint32_t low  = 0;
  for (int attempt = 0; attempt < 3; ++attempt) {
    low                      = ReadCoreCsr(kCoreCsrMinstret);
    const uint32_t next_high = ReadCoreCsr(kCoreCsrMinstreth);
    // The low word didn't wrap while it was read.
    if (next_high == high)
      break;
    high = next_high;
  }
  state->minstret = (static_cast<uint64_t>(high) << 32) | low;
  return true;
}

AxiWResp CoreMiniAxiSimulator::WriteCallback(const AxiAddr &addr, const AxiWData &data) {
  if (IsDdrAddress(addr.addr_bits_addr)) {
    uint32_t offset           = addr.addr_bits_addr - 0x80000000;
    uint32_t aligned_offset   = offset & ~15;
    const uint8_t *write_data = reinterpret_cast<const uint8_t *>(&data.write_data_bits_data[0]);
    for (int i = 0; i < 16; i++) {
      if (data.write_data_bits_strb & (1 << i)) {
        if (aligned_offset + i < ddr_memory_.size()) {
          ddr_memory_[aligned_offset + i] = write_data[i];
        } else {
          assert(false && "NPU DDR write out of bounds");
        }
      }
    }
    AxiWResp resp;
    resp.write_resp_bits_id   = addr.addr_bits_id;
    resp.write_resp_bits_resp = 0;
    return resp;
  }

  CoralNPUMailbox &mailbox  = wrapper_.mailbox();
  uint8_t *mailbox_data     = reinterpret_cast<uint8_t *>(mailbox.message);
  const uint8_t *write_data = reinterpret_cast<const uint8_t *>(&data.write_data_bits_data[0]);
  for (int i = 0; i < 16; i++) {
    if (data.write_data_bits_strb & (1 << i)) {
      mailbox_data[i] = write_data[i];
    }
  }

  AxiWResp resp;
  resp.write_resp_bits_id   = addr.addr_bits_id;
  resp.write_resp_bits_resp = 0;
  return resp;
}

AxiRData CoreMiniAxiSimulator::ReadCallback(const AxiAddr &addr) {
  if (IsDdrAddress(addr.addr_bits_addr)) {
    uint32_t offset         = addr.addr_bits_addr - 0x80000000;
    uint32_t aligned_offset = offset & ~15;
    AxiRData data;
    uint8_t *read_data = reinterpret_cast<uint8_t *>(&(data.read_data_bits_data[0]));
    if (aligned_offset + 16 <= ddr_memory_.size()) {
      memcpy(read_data, ddr_memory_.data() + aligned_offset, 16);
    } else {
      assert(false && "NPU DDR read out of bounds");
    }
    data.read_data_bits_id   = addr.addr_bits_id;
    data.read_data_bits_resp = 0;
    data.read_data_bits_last = 1;
    return data;
  }

  const CoralNPUMailbox &mailbox = wrapper_.mailbox();
  const uint8_t *mailbox_data    = reinterpret_cast<const uint8_t *>(mailbox.message);
  AxiRData data;
  uint8_t *read_data = reinterpret_cast<uint8_t *>(&(data.read_data_bits_data[0]));
  for (int i = 0; i < 16; i++) {
    read_data[i] = mailbox_data[i];
  }

  data.read_data_bits_id   = addr.addr_bits_id;
  data.read_data_bits_resp = 0;
  data.read_data_bits_last = 1;

  return data;
}

extern "C" CoralNPUSimulator *coralnpu_simulator_verilator_create(void) {
  return new CoreMiniAxiSimulator();
}

CoralNPUSimulator *coralnpu_simulator_verilator_create_with_options(
    const CoralNPUSimulatorOptions &options) {
  return new CoreMiniAxiSimulator(options);
}
