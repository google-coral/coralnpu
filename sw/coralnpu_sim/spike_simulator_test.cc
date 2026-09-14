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

#include <cstdint>
#include <cstdlib>
#include <memory>
#include <optional>
#include <string>
#include <vector>

#include "gtest/gtest.h"
#include "sw/coralnpu_sim/spike_cosim_dpi.h"
#include "tools/cpp/runfiles/runfiles.h"

using bazel::tools::cpp::runfiles::Runfiles;
using coralnpu::sim::SpikeSimulator;
using coralnpu::sim::SpikeSimulatorOptions;

namespace {

std::string GetTestElfPath() {
  std::string error;
  std::unique_ptr<Runfiles> runfiles(Runfiles::CreateForTest(&error));
  if (runfiles != nullptr) {
    std::string path =
        runfiles->Rlocation("coralnpu_hw/tests/cocotb/rvv/arithmetics/rvv_add_int8_m1.elf");
    if (!path.empty()) {
      return path;
    }
  }
  const char *srcdir = std::getenv("TEST_SRCDIR");
  if (srcdir != nullptr) {
    return std::string(srcdir) + "/coralnpu_hw/tests/cocotb/rvv/arithmetics/rvv_add_int8_m1.elf";
  }
  return "tests/cocotb/rvv/arithmetics/rvv_add_int8_m1.elf";
}

TEST(SpikeSimulatorTest, InitializesWithDefaultOptions) {
  SpikeSimulator sim;
  EXPECT_EQ(sim.GetCycleCount(), 0);
  EXPECT_FALSE(sim.IsHalted());
}

TEST(SpikeSimulatorTest, GprReadWriteAndX0Invariant) {
  SpikeSimulator sim;

  // x0 and zero are hardwired to 0
  sim.WriteRegister("x0", 0x12345678);
  EXPECT_EQ(sim.ReadRegister("x0"), 0);

  sim.WriteRegister("zero", 0x87654321);
  EXPECT_EQ(sim.ReadRegister("zero"), 0);
  EXPECT_EQ(sim.ReadRegister("x0"), 0);

  // Malformed register names should return 0 / not match
  EXPECT_EQ(sim.ReadRegister("x1foo"), 0);
  EXPECT_EQ(sim.ReadRegister("f1foo"), 0);

  // Write and read GPRs
  sim.WriteRegister("x1", 0xDEADBEEF);
  EXPECT_EQ(sim.ReadRegister("x1"), 0xDEADBEEF);

  sim.WriteRegister("ra", 0xCAFEBABE);
  EXPECT_EQ(sim.ReadRegister("x1"), 0xCAFEBABE);
  EXPECT_EQ(sim.ReadRegister("ra"), 0xCAFEBABE);

  sim.WriteRegister("x10", 0x12344321);
  EXPECT_EQ(sim.ReadRegister("x10"), 0x12344321);
  EXPECT_EQ(sim.ReadRegister("a0"), 0x12344321);
}

TEST(SpikeSimulatorTest, FprReadWrite) {
  SpikeSimulator sim;

  sim.WriteRegister("f0", 0x3F800000);  // 1.0f in IEEE 754
  EXPECT_EQ(sim.ReadRegister("f0") & 0xFFFFFFFFULL, 0x3F800000);

  sim.WriteRegister("fa0", 0x40000000);  // 2.0f
  EXPECT_EQ(sim.ReadRegister("f10") & 0xFFFFFFFFULL, 0x40000000);
}

TEST(SpikeSimulatorTest, CsrReadWrite) {
  SpikeSimulator sim;

  // Standard CSRs: enable FS (floating point) in mstatus (bits 14:13 = 0x6000)
  sim.WriteRegister("mstatus", 0x6000);
  EXPECT_EQ(sim.ReadRegister("mstatus") & 0x6000, 0x6000);

  // Float CSRs (valid now that FS is enabled)
  sim.WriteRegister("fcsr", 0x7);
  EXPECT_EQ(sim.ReadRegister("fcsr"), 0x7);

  sim.WriteRegister("fflags", 0x1);
  EXPECT_EQ(sim.ReadRegister("fflags"), 0x1);

  sim.WriteRegister("frm", 0x2);
  EXPECT_EQ(sim.ReadRegister("frm"), 0x2);

  // Unknown CSR returns 0 without crashing
  EXPECT_EQ(sim.ReadRegister("unknown_csr_xyz"), 0);
  sim.WriteRegister("unknown_csr_xyz", 0x123);  // Should not crash
}

TEST(SpikeSimulatorTest, MtvecDirectModeOnly) {
  SpikeSimulator sim;

  // Verify that mtvec only supports Direct trap mode (MODE=0, bits [1:0] == 00).
  // Writing values with non-zero MODE bits (e.g. 0x1 for Vectored mode, 0x3 for reserved)
  // must be masked to 0 per RISC-V Privileged Architecture Specification (Section 3.1.7)
  // for implementations that do not support Vectored trap mode.
  sim.WriteRegister("mtvec", 0x10001);
  EXPECT_EQ(sim.ReadRegister("mtvec"), 0x10000);

  sim.WriteRegister("mtvec", 0x20003);
  EXPECT_EQ(sim.ReadRegister("mtvec"), 0x20000);

  // Verify that after Reset(), the direct mode WARL invariant is preserved.
  sim.Reset();
  sim.WriteRegister("mtvec", 0x30001);
  EXPECT_EQ(sim.ReadRegister("mtvec"), 0x30000);
}

TEST(SpikeSimulatorTest, VectorRegisterReadWrite128Bit) {
  SpikeSimulator sim;

  uint32_t write_words[4] = {0x11111111, 0x22222222, 0x33333333, 0x44444444};
  EXPECT_TRUE(sim.WriteVectorRegister(1, write_words));

  uint32_t read_words[4] = {0};
  EXPECT_TRUE(sim.ReadVectorRegister(1, read_words));

  for (int i = 0; i < 4; ++i) {
    EXPECT_EQ(read_words[i], write_words[i]) << "Mismatch at word " << i;
  }

  // Out of range indices
  EXPECT_FALSE(sim.ReadVectorRegister(-1, read_words));
  EXPECT_FALSE(sim.ReadVectorRegister(32, read_words));
  EXPECT_FALSE(sim.WriteVectorRegister(-1, write_words));
  EXPECT_FALSE(sim.WriteVectorRegister(32, write_words));
}

TEST(SpikeSimulatorTest, MemoryReadWrite) {
  SpikeSimulator sim;
  uint64_t test_addr = 0x00001000;  // Inside ITCM region

  sim.WriteWord(test_addr, 0xAABBCCDD);
  uint32_t read_word = 0;
  EXPECT_TRUE(sim.ReadMemory(test_addr, &read_word, sizeof(read_word)));
  EXPECT_EQ(read_word, 0xAABBCCDD);

  sim.WritePtr(test_addr + 8, 0x1234567887654321ULL);
  uint32_t read_ptr = 0;
  EXPECT_TRUE(sim.ReadMemory(test_addr + 8, &read_ptr, sizeof(read_ptr)));
  EXPECT_EQ(read_ptr, 0x87654321);
}

TEST(SpikeSimulatorTest, LoadProgramWithNulloptUsesElfEntry) {
  SpikeSimulator sim;
  std::string elf_path = GetTestElfPath();

  ASSERT_TRUE(sim.LoadProgram(elf_path, std::nullopt));
  // rvv_add_int8_m1 has entry point at 0x00000000
  EXPECT_EQ(sim.GetPC(), 0x00000000);
}

TEST(SpikeSimulatorTest, LoadProgramWithExplicitZeroEntryPoint) {
  SpikeSimulator sim;
  std::string elf_path = GetTestElfPath();

  ASSERT_TRUE(sim.LoadProgram(elf_path, 0x00000000));
  EXPECT_EQ(sim.GetPC(), 0x00000000);
}

TEST(SpikeSimulatorTest, LoadProgramWithCustomEntryPoint) {
  SpikeSimulator sim;
  std::string elf_path = GetTestElfPath();

  ASSERT_TRUE(sim.LoadProgram(elf_path, 0x00000040));
  EXPECT_EQ(sim.GetPC(), 0x00000040);
}

TEST(SpikeSimulatorTest, LoadProgramFailsOnInvalidFile) {
  SpikeSimulator sim;
  EXPECT_FALSE(sim.LoadProgram("/path/does/not/exist.elf"));
}

TEST(SpikeSimulatorTest, StepExecutesInstructionsAndTracksCycleCount) {
  SpikeSimulator sim;
  std::string elf_path = GetTestElfPath();
  ASSERT_TRUE(sim.LoadProgram(elf_path));

  EXPECT_EQ(sim.GetCycleCount(), 0);
  int stepped = sim.Step(5);
  EXPECT_EQ(stepped, 5);
  EXPECT_EQ(sim.GetCycleCount(), 5);

  stepped = sim.Step(10);
  EXPECT_EQ(stepped, 10);
  EXPECT_EQ(sim.GetCycleCount(), 15);
}

TEST(SpikeSimulatorTest, StepReturnsExecutedCountOnHalt) {
  SpikeSimulator sim;
  std::string elf_path = GetTestElfPath();
  ASSERT_TRUE(sim.LoadProgram(elf_path));

  // Run until halt or up to a maximum step limit
  int total_executed = 0;
  while (!sim.IsHalted() && total_executed < 10000) {
    int s = sim.Step(100);
    if (s == 0)
      break;
    total_executed += s;
  }

  EXPECT_TRUE(sim.IsHalted());
  // When already halted, Step(10) must return 0, not 10!
  int step_after_halt = sim.Step(10);
  EXPECT_EQ(step_after_halt, 0);
}

TEST(SpikeDpiTest, InitLoadStepAndFiniLifecycle) {
  EXPECT_EQ(spike_init(), 0);
  std::string elf_path = GetTestElfPath();

  // Test loading with nullopt (has_entry_point = 0)
  EXPECT_EQ(spike_load_program(elf_path.c_str(), 0, 0), 0);
  uint32_t pc = 0xFFFFFFFF;
  EXPECT_EQ(spike_get_register("pc", &pc), 0);
  EXPECT_EQ(pc, 0x00000000);

  // Test stepping
  EXPECT_EQ(spike_step(1), 0);

  // Test register access
  EXPECT_EQ(spike_set_register("x3", 0x42), 0);
  uint32_t x3 = 0;
  EXPECT_EQ(spike_get_register("x3", &x3), 0);
  EXPECT_EQ(x3, 0x42);

  // Test vector register access
  svLogicVecVal vec_val[4];
  EXPECT_EQ(spike_get_vector_register("v0", vec_val), 0);

  // Test reset
  EXPECT_EQ(spike_reset(), 0);

  // Test fini
  EXPECT_EQ(spike_fini(), 0);
  // After fini, step should fail gracefully
  EXPECT_EQ(spike_step(1), -1);
  EXPECT_TRUE(spike_is_halted());
}

TEST(SpikeDpiTest, LoadProgramWithCustomEntryViaDpi) {
  EXPECT_EQ(spike_init(), 0);
  std::string elf_path = GetTestElfPath();

  // Load with has_entry_point = 1 and custom entry 0x80
  EXPECT_EQ(spike_load_program(elf_path.c_str(), 0x00000080, 1), 0);
  uint32_t pc = 0;
  EXPECT_EQ(spike_get_register("pc", &pc), 0);
  EXPECT_EQ(pc, 0x00000080);

  EXPECT_EQ(spike_fini(), 0);
}

TEST(SpikeDpiTest, RobustnessAndNullSafety) {
  EXPECT_EQ(spike_init(), 0);

  // Null pointers should return error (-1) and not crash
  EXPECT_EQ(spike_load_program(nullptr, 0, 0), -1);
  EXPECT_EQ(spike_get_register(nullptr, nullptr), -1);
  uint32_t val = 0;
  EXPECT_EQ(spike_get_register(nullptr, &val), -1);
  EXPECT_EQ(spike_get_register("x1", nullptr), -1);
  EXPECT_EQ(spike_set_register(nullptr, 10), -1);

  // Step 0 should return 0 (success, no-op)
  EXPECT_EQ(spike_step(0), 0);

  svLogicVecVal vec_val[4];
  EXPECT_EQ(spike_get_vector_register(nullptr, vec_val), -1);
  EXPECT_EQ(spike_get_vector_register("v1", nullptr), -1);
  EXPECT_EQ(spike_get_vector_register("invalid_v", vec_val), -1);
  EXPECT_EQ(spike_get_vector_register("v99", vec_val), -1);
  EXPECT_EQ(spike_get_vector_register("v1extra", vec_val), -1);

  EXPECT_EQ(spike_fini(), 0);
}

}  // namespace
