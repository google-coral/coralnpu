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

#include <cstring>
#include <iostream>
#include <string>

#include "sim_ctrl_extension.h"
#include "sram_backdoor.h"
#include "verilated_toplevel.h"
#include "verilator_memutil.h"
#include "verilator_sim_ctrl.h"

namespace {

// SimCtrl extension that backdoor-loads an ELF into the Chisel SRAMs once
// the SRAM modules have registered themselves with sram_backdoor.cc. The
// registration happens in SV `initial` blocks, which Verilator runs during
// the first eval(); waiting until the first OnClock callback guarantees they
// are in the registered_srams map.
class BackdoorElfLoader : public SimCtrlExtension {
 public:
  bool ParseCLIArguments(int argc, char** argv, bool& exit_app) override {
    static const char kFlag[] = "--load_elf=";
    static const size_t kFlagLen = sizeof(kFlag) - 1;
    for (int i = 1; i < argc; ++i) {
      if (argv[i] && std::strncmp(argv[i], kFlag, kFlagLen) == 0) {
        path_ = argv[i] + kFlagLen;
      }
    }
    return true;
  }

  void OnClock(unsigned long sim_time) override {
    if (loaded_ || path_.empty()) return;
    std::cerr << "[Backdoor] Loading ELF: " << path_ << std::endl;
    sram_clear();
    sram_load_elf(path_.c_str());
    loaded_ = true;
  }

 private:
  std::string path_;
  bool loaded_ = false;
};

}  // namespace

#if defined(CHISEL_SUBSYSTEM_HIGHMEM)
constexpr bool highmem = true;
#else
constexpr bool highmem = false;
#endif

int main(int argc, char **argv) {
  chip_verilator top;
  VerilatorMemUtil memutil;
  VerilatorSimCtrl &simctrl = VerilatorSimCtrl::GetInstance();
  simctrl.SetTop(&top, &top.clk_i, &top.rst_ni,
                 VerilatorSimCtrlFlags::ResetPolarityNegative);

  constexpr uint32_t itcm_size = highmem ? 0x100000 : 0x2000;
  constexpr uint32_t dtcm_size = highmem ? 0x100000 : 0x8000;
  constexpr uint32_t dtcm_addr = highmem ? 0x100000 : 0x10000;
  // NB: Final parameter here is "width" of your memory, penultimate parameter
  // is "depth".
  MemArea rom("TOP.chip_verilator.i_coralnpu_soc.i_rom.u_prim_rom", 0x8000 / 4,
              4);
  MemArea sram("TOP.chip_verilator.i_coralnpu_soc.i_sram", 0x400000 / 4, 4);
  MemArea itcm(
      "TOP.chip_verilator.i_coralnpu_soc.i_coralnpu_core.coreAxi.itcm.sram."
      "sramModules_0",
      itcm_size / 16, 16);
  MemArea dtcm(
      "TOP.chip_verilator.i_coralnpu_soc.i_coralnpu_core.coreAxi.dtcm.sram."
      "sramModules_0",
      dtcm_size / 16, 16);

  memutil.RegisterMemoryArea("rom", 0x10000000, &rom);
  memutil.RegisterMemoryArea("sram", 0x20000000, &sram);
  memutil.RegisterMemoryArea("itcm", 0x00000000, &itcm);
  memutil.RegisterMemoryArea("dtcm", dtcm_addr, &dtcm);
  simctrl.RegisterExtension(&memutil);

  BackdoorElfLoader backdoor_loader;
  simctrl.RegisterExtension(&backdoor_loader);

  simctrl.SetInitialResetDelay(20);
  simctrl.SetResetDuration(10);

  std::cout << "Simulation of CoralNPU SoC (" << (highmem ? "Highmem" : "Default") << ")" << std::endl
            << "======================" << std::endl
            << std::endl;

  return simctrl.Exec(argc, argv).first;
}
