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

#ifndef HW_SIM_CORALNPU_SIMULATOR_H_
#define HW_SIM_CORALNPU_SIMULATOR_H_

#include <cstddef>
#include <cstdint>
#include <functional>
#include <string>

#include "hw_sim/mailbox.h"

struct CoralNPUSimulatorOptions {
  using CycleCallback = std::function<void(uint64_t cycle_count)>;

  CycleCallback cycle_callback   = nullptr;
  uint64_t cycle_callback_period = 1000;
};

// CoralNPUSimulator, the types it uses and CoralNPUMailbox (hw_sim/mailbox.h)
// must stay the same as in coralnpu-mpact's sim/hw_sim/coralnpu_simulator.h:
// a host (e.g. the IREE runtime) can use simulators built against either copy.

// Called before each executed instruction with its address, its encoding (the
// low 16 bits for compressed instructions) and, if requested, its disassembly.
using TraceCallback =
    std::function<void(uint32_t pc, uint32_t instruction, std::string &disassembly)>;

// Called for each data access of the core: the loads and stores of executed
// instructions, one call per active vector element. Host accesses (ReadMem,
// WriteMem), instruction fetches and DMA transfers are not reported.
using MemoryAccessCallback = std::function<void(uint32_t address, uint32_t size, bool is_store)>;

// State of the core, read with ReadCoreState.
struct CoralNPUCoreState {
  // Whether the core halted, and whether it halted on a fault. A core that
  // waits for an interrupt (wfi) isn't halted.
  bool halted = false;
  bool fault  = false;
  // The program counter and the machine trap CSRs.
  uint32_t pc     = 0;
  uint32_t mepc   = 0;
  uint32_t mtval  = 0;
  uint32_t mcause = 0;
  // The number of retired instructions.
  uint64_t minstret = 0;
};

class CoralNPUSimulator {
 public:
  virtual ~CoralNPUSimulator() = default;

  // Functions for reading/writing memory and Mailbox.
  virtual void ReadMem(uint32_t addr, size_t size, char *data)        = 0;
  virtual const CoralNPUMailbox &ReadMailbox(void)                    = 0;
  virtual void WriteMem(uint32_t addr, size_t size, const char *data) = 0;
  virtual void WriteMailbox(const CoralNPUMailbox &mailbox)           = 0;

  // Waits until the core stops: it halts or, on some simulators, waits for an
  // interrupt (wfi). Waits at most |timeout|, in a unit that depends on the
  // simulator (e.g. cycles in RTL simulation, milliseconds on hardware); a
  // |timeout| <= 0 selects the simulator's default. Simulators that always
  // run until the core stops ignore |timeout|. Returns false if the core
  // didn't stop: the wait timed out or the simulation failed (after a
  // timeout, ReadCoreState, if supported, shows that the core didn't halt).
  virtual bool WaitForTermination(int timeout) = 0;

  // Starts the core at |start_addr| and returns without waiting for it. Call
  // WaitForTermination next: on some simulators (e.g. MPACT), the core
  // executes instructions only in WaitForTermination.
  virtual void Run(uint32_t start_addr) = 0;

  // Returns the total simulated cycle count.
  virtual uint64_t GetCycleCount() const = 0;

  // Sets a callback for tracing instructions, with their disassembly if
  // |disasm|, or removes it if |callback| is empty. Set it before Run. Returns
  // false if the simulator doesn't support tracing.
  virtual bool SetTraceCallback(TraceCallback /*callback*/, bool /*disasm*/) { return false; }

  // Sets a callback for the core's data accesses, or removes it if |callback|
  // is empty. Set it before Run. Returns false if the simulator doesn't
  // support it.
  virtual bool SetMemoryAccessCallback(MemoryAccessCallback /*callback*/) { return false; }

  // Reads the state of the core into |state|. Returns false if the simulator
  // can't read it.
  virtual bool ReadCoreState(CoralNPUCoreState * /*state*/) { return false; }
};

extern "C" CoralNPUSimulator *coralnpu_simulator_verilator_create(void);

CoralNPUSimulator *coralnpu_simulator_verilator_create_with_options(
    const CoralNPUSimulatorOptions &options);

#endif  // HW_SIM_CORALNPU_SIMULATOR_H_
