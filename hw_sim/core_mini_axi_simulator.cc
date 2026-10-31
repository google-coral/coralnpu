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

#include <sys/mman.h>

#include <cassert>
#include <cstring>
#include <memory>
#include <new>
#include <string>
#include <utility>
#include <vector>

#include "hw_sim/coralnpu_simulator.h"
#include "hw_sim/core_mini_axi_wrapper.h"

namespace {

// The core's CSR block (CoreAxiCSR.scala): the status register (bit 0: halted,
// bit 1: fault) and the CSR values the core exports (io.csr.out.value in
// scalar/Csr.scala), one word each.
constexpr uint32_t kCoreCsrBase         = 0x30000;
constexpr uint32_t kHighmemCoreCsrBase  = 0x200000;
constexpr uint32_t kCoreCsrStatusOffset = 0x8;
constexpr uint32_t kCoreCsrValuesOffset = 0x100;
enum CoreCsrValue : uint32_t {
  kCoreCsrPc        = 0,
  kCoreCsrMepc      = 1,
  kCoreCsrMtval     = 2,
  kCoreCsrMcause    = 3,
  kCoreCsrMinstret  = 6,
  kCoreCsrMinstreth = 7,
};

// Default 8 KiB ITCM ([0, 0x2000)) and 32 KiB DTCM ([0x10000, 0x18000)) bounds
// (MemoryRegions.default in Parameters.scala). Programs outside these bounds
// get the 1 MiB ITCM/DTCM highmem RTL model (VVmeCoreMiniHighmemAxi).
constexpr uint32_t kDefaultItcmEnd   = 0x00002000;
constexpr uint32_t kDefaultDtcmStart = 0x00010000;
constexpr uint32_t kDefaultDtcmEnd   = 0x00018000;

// The number of cycles WaitForTermination waits if its timeout isn't positive.
constexpr int kDefaultTimeoutCycles = 10000;

constexpr size_t kDdrMemorySize = 1024 * 1024 * 1024;  // 1GB DDR

struct DdrDeleter {
  void operator()(uint8_t *p) const noexcept { munmap(p, kDdrMemorySize); }
};

}  // namespace

class CoreMiniAxiSimulator final : public CoralNPUSimulator {
 public:
  explicit CoreMiniAxiSimulator(const CoralNPUSimulatorOptions &options = {})
      : context_(), options_(options) {
    // Match the models' --threads; the context defaults to one per host CPU.
    // threads() also turns on worker CPU pinning, which only adds startup cost.
    context_.threads(CORALNPU_VERILATOR_THREADS);
    context_.useNumaAssign(false);
    // Reserve the 1 GiB DDR address range lazily with anonymous mmap so
    // untouched pages are not faulted in or zero-filled on construction.
    void *mapped =
        mmap(nullptr, kDdrMemorySize, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mapped == MAP_FAILED) {
      throw std::bad_alloc();
    }
    ddr_memory_.reset(static_cast<uint8_t *>(mapped));
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
  const CoralNPUSimulatorOptions options_;
  std::unique_ptr<uint8_t[], DdrDeleter> ddr_memory_;
  std::unique_ptr<CoreMiniAxiWrapperBase> wrapper_;
  bool highmem_ = false;
  CoralNPUMailbox mailbox_;
  std::vector<std::pair<uint32_t, std::string>> pending_tcm_writes_;

  bool IsDdrAddress(uint32_t addr) { return addr >= 0x80000000 && addr < 0xC0000000; }

  // Returns the base address of the active core's CSR block.
  uint32_t CsrBase() const { return highmem_ ? kHighmemCoreCsrBase : kCoreCsrBase; }

  // Lazily initializes and returns the active standard or highmem Verilated
  // wrapper, replaying any buffered initial ITCM writes.
  CoreMiniAxiWrapperBase &GetWrapper() {
    if (!wrapper_) {
      if (highmem_) {
        wrapper_ = std::make_unique<CoreMiniHighmemAxiWrapper>(&context_, options_);
      } else {
        wrapper_ = std::make_unique<CoreMiniAxiWrapper>(&context_, options_);
      }
      wrapper_->RegisterReadCallback([this](const AxiAddr &a) { return this->ReadCallback(a); });
      wrapper_->RegisterWriteCallback(
          [this](const AxiAddr &a, const AxiWData &d) { return this->WriteCallback(a, d); });
      wrapper_->Reset();
      for (const auto &[addr, bytes] : pending_tcm_writes_) {
        wrapper_->Write(addr, bytes.size(), bytes.data());
      }
      pending_tcm_writes_.clear();
    }
    return *wrapper_;
  }

  // Reads the word at |addr|.
  uint32_t ReadWord(uint32_t addr);
  // Reads CSR value |index| from the core's CSR block.
  uint32_t ReadCoreCsr(CoreCsrValue index) {
    return ReadWord(CsrBase() + kCoreCsrValuesOffset + 4 * index);
  }

  AxiWResp WriteCallback(const AxiAddr &, const AxiWData &);
  AxiRData ReadCallback(const AxiAddr &);
};

void CoreMiniAxiSimulator::ReadMem(uint32_t addr, size_t size, char *data) {
  if (IsDdrAddress(addr)) {
    uint32_t offset = addr - 0x80000000;
    if (offset + size <= kDdrMemorySize) {
      memcpy(data, ddr_memory_.get() + offset, size);
    } else {
      assert(false && "DDR read out of bounds");
    }
  } else {
    std::vector<uint8_t> read_result = GetWrapper().Read(addr, size);
    memcpy(data, read_result.data(), size);
  }
}

const CoralNPUMailbox &CoreMiniAxiSimulator::ReadMailbox(void) { return mailbox_; }

void CoreMiniAxiSimulator::WriteMem(uint32_t addr, size_t size, const char *data) {
  if (IsDdrAddress(addr)) {
    uint32_t offset = addr - 0x80000000;
    if (offset + size <= kDdrMemorySize) {
      memcpy(ddr_memory_.get() + offset, data, size);
    } else {
      assert(false && "DDR write out of bounds");
    }
  } else {
    if (!wrapper_) {
      // Buffer writes within the default 8 KiB ITCM until a later write reveals
      // whether the program fits in the default TCMs or needs 1 MiB highmem.
      if (addr + size <= kDefaultItcmEnd) {
        pending_tcm_writes_.emplace_back(addr, std::string(data, size));
        return;
      }
      highmem_ = addr + size > kDefaultDtcmEnd || addr < kDefaultDtcmStart;
    }
    GetWrapper().Write(addr, size, data);
  }
}

void CoreMiniAxiSimulator::WriteMailbox(const CoralNPUMailbox &mailbox) { mailbox_ = mailbox; }

void CoreMiniAxiSimulator::Run(uint32_t start_addr) {
  CoreMiniAxiWrapperBase &w = GetWrapper();
  const uint32_t csr_base   = CsrBase();
  w.WriteWord(csr_base + 4, start_addr);
  w.WriteWord(csr_base, 1u);
  w.WriteWord(csr_base, 0u);
}

bool CoreMiniAxiSimulator::WaitForTermination(int timeout) {
  return GetWrapper().WaitForTermination(timeout > 0 ? timeout : kDefaultTimeoutCycles);
}

uint64_t CoreMiniAxiSimulator::GetCycleCount() const {
  return wrapper_ ? wrapper_->cycle_count() : 0;
}

uint32_t CoreMiniAxiSimulator::ReadWord(uint32_t addr) {
  uint32_t word = 0;
  ReadMem(addr, sizeof(word), reinterpret_cast<char *>(&word));
  return word;
}

bool CoreMiniAxiSimulator::ReadCoreState(CoralNPUCoreState *state) {
  // Word by word: the CSR block registers are one word wide.
  const uint32_t status = ReadWord(CsrBase() + kCoreCsrStatusOffset);
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
        if (aligned_offset + i < kDdrMemorySize) {
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

  uint8_t *mailbox_data     = reinterpret_cast<uint8_t *>(mailbox_.message);
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
    if (aligned_offset + 16 <= kDdrMemorySize) {
      memcpy(read_data, ddr_memory_.get() + aligned_offset, 16);
    } else {
      assert(false && "NPU DDR read out of bounds");
    }
    data.read_data_bits_id   = addr.addr_bits_id;
    data.read_data_bits_resp = 0;
    data.read_data_bits_last = 1;
    return data;
  }

  const uint8_t *mailbox_data = reinterpret_cast<const uint8_t *>(mailbox_.message);
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
