// Copyright 2024 Google LLC
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

#include <optional>
#include <string>
#include <thread>

#include "absl/flags/flag.h"
#include "absl/flags/parse.h"
#include "absl/flags/usage.h"
#include "absl/log/check.h"
#include "absl/log/initialize.h"
#include "absl/log/log.h"
#include "tests/verilator_sim/coralnpu/core_mini_axi_tb.h"
#include "tests/verilator_sim/sysc_tb.h"

/* clang-format off */
#include <systemc.h>
/* clang-format on */

ABSL_FLAG(int, cycles, 100000000, "Simulation cycles");
ABSL_FLAG(bool, trace, false, "Dump VCD trace");
ABSL_FLAG(std::string, binary, "", "Binary to execute");
ABSL_FLAG(bool, debug_axi, false, "Enable AXI traffic debugging");
ABSL_FLAG(bool, instr_trace, false, "Log instructions to console");
ABSL_FLAG(bool, backdoor_load, false, "Enable high-speed backdoor code loading");

static bool run(const char* name, const std::string binary, const int cycles,
                const bool trace, const bool debug_axi, const bool instr_trace,
                const bool backdoor_load) {
  absl::Mutex halted_mtx;
  absl::CondVar halted_cv;
  CoreMiniAxi_tb tb(CoreMiniAxi_tb::kCoreMiniAxiModelName, cycles, /* random= */ false, debug_axi,
                    instr_trace, backdoor_load,
                    /*wfi_cb=*/std::nullopt,
                    /*halted_cb=*/[&halted_mtx, &halted_cv]() {
                      absl::MutexLock lock_(&halted_mtx);
                      halted_cv.SignalAll();
                    });
  // Ensure we call sc_start @0 time, before we startup anything else.
  // This allows Verilog `initial` blocks to run before we try to interact with the
  // DUT model.
  sc_start(SC_ZERO_TIME);

  if (trace) {
    tb.trace(tb.core());
  }

  std::thread sc_main_thread([&tb]() { tb.start(); });

  CHECK_OK(tb.LoadElfSync(binary));
  CHECK_OK(tb.ClockGateSync(false));
  CHECK_OK(tb.ResetAsync(false));

  {
    absl::MutexLock lock_(&halted_mtx);
    halted_cv.Wait(&halted_mtx);
  }

  if (!tb.io_fault && !tb.tohost_halt) {
    CHECK_OK(tb.CheckStatusSync());
  }

  sc_stop();
  sc_main_thread.join();
  return (!tb.io_fault && !(tb.tohost_halt && tb.tohost_val != 1));
}

extern "C" int sc_main(int argc, char** argv) {
  absl::InitializeLog();
  absl::SetProgramUsageMessage("CoreMiniAxi simulator");
  auto args = absl::ParseCommandLine(argc, argv);

  // Pass clean arguments to Verilator.
  int v_argc = args.size();
  char** v_argv = &args[0];
  Verilated::commandArgs(v_argc, v_argv);

  if (absl::GetFlag(FLAGS_binary) == "") {
    LOG(ERROR) << "--binary is required!";
    return -1;
  }

  return run(Sysc_tb::get_name(argv[0]), absl::GetFlag(FLAGS_binary),
      absl::GetFlag(FLAGS_cycles), absl::GetFlag(FLAGS_trace),
      absl::GetFlag(FLAGS_debug_axi), absl::GetFlag(FLAGS_instr_trace),
      absl::GetFlag(FLAGS_backdoor_load)) ? 0 : 1;
}
