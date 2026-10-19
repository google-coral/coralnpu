// Copyright 2026 Google LLC
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

#include "utils/fst_query/fst_query.h"

#include <cstdint>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "absl/strings/str_cat.h"
#include "fstcpp/fstcpp.h"
#include "fstcpp/fstcpp_writer.h"
#include "gtest/gtest.h"
#include "re2/re2.h"

namespace fst_query {
namespace {

class FstQueryTest : public ::testing::Test {
 protected:
  std::string TempFstPath(const std::string &name) {
    const char *test_tmpdir = std::getenv("TEST_TMPDIR");
    std::filesystem::path dir =
        test_tmpdir ? std::filesystem::path(test_tmpdir) : std::filesystem::temp_directory_path();
    return (dir / name).string();
  }

  static std::string FindRunfile(const std::string &rel_path) {
    const char *srcdir = std::getenv("TEST_SRCDIR");
    if (srcdir != nullptr) {
      for (const char *workspace : {"coralnpu_hw", "_main", ""}) {
        std::filesystem::path p = std::filesystem::path(srcdir);
        if (*workspace)
          p = p / workspace;
        p = p / rel_path;
        if (std::filesystem::exists(p)) {
          return p.string();
        }
      }
    }
    std::filesystem::path local = std::filesystem::path(rel_path);
    if (std::filesystem::exists(local)) {
      return local.string();
    }
    return rel_path;
  }

  struct RunResult {
    int exit_code;
    std::string out;
    std::string err;
  };

  RunResult Execute(const std::vector<std::string> &args) {
    std::vector<const char *> argv;
    argv.reserve(args.size() + 1);
    argv.push_back("fst_query");
    for (const auto &a : args) {
      argv.push_back(a.c_str());
    }
    std::ostringstream out;
    std::ostringstream err;
    int rc = RunFstQuery(static_cast<int>(argv.size()), argv.data(), out, err);
    return RunResult{rc, out.str(), err.str()};
  }
};

TEST_F(FstQueryTest, UsageAndMissingFileErrors) {
  {
    auto res = Execute({});
    EXPECT_EQ(res.exit_code, 1);
    EXPECT_TRUE(res.out.empty());
    EXPECT_NE(res.err.find("Usage: fst_query <fst_file>"), std::string::npos);
  }
  {
    auto res = Execute({"--list"});
    EXPECT_EQ(res.exit_code, 1);
    EXPECT_TRUE(res.out.empty());
    EXPECT_NE(res.err.find("Usage: fst_query <fst_file>"), std::string::npos);
  }
  {
    auto res = Execute({TempFstPath("nonexistent_file.fst")});
    EXPECT_EQ(res.exit_code, 1);
    EXPECT_NE(res.err.find("Failed to open FST file:"), std::string::npos);
  }
  {
    auto res = Execute({TempFstPath("nonexistent_file.fst"), "--list"});
    EXPECT_EQ(res.exit_code, 1);
    EXPECT_NE(res.err.find("Failed to open FST file:"), std::string::npos);
  }
}

TEST_F(FstQueryTest, EmptyOrTruncatedFileHandledGracefully) {
  std::string path = TempFstPath("truncated.fst");
  {
    std::ofstream ofs(path, std::ios::binary);
    ofs.write("bad", 3);
  }
  auto res = Execute({path, "--list"});
  EXPECT_EQ(res.exit_code, 0);
  EXPECT_TRUE(res.out.empty());
  EXPECT_TRUE(res.err.empty());

  // Malformed wave block with overlong LEB128 (>10 continuation bytes) and
  // out-of-bounds compressed section lengths should not trigger UB or OOB reads.
  std::string malformed_path = TempFstPath("malformed_wave.fst");
  {
    fst::Writer writer(malformed_path);
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
    fst::Handle h = writer.createVar(fst::Hierarchy::VarType::VCD_WIRE,
                                     fst::Hierarchy::VarDirection::IMPLICIT, 1, "sig", 0);
    writer.upscope();
    writer.emitValueChange(h, uint64_t{0});
    writer.emitTimeChange(0);
    writer.close();

    // Append a synthetic WAVE_DATA_VERSION3 block with overlong LEB128 and OOB lengths
    std::ofstream ofs(malformed_path, std::ios::binary | std::ios::app);
    uint8_t btype = static_cast<uint8_t>(fst::BlockType::WAVE_DATA_VERSION3);
    std::vector<uint8_t> payload(64, 0);
    // start_time = 10, end_time = 20 (big-endian) at offsets 0..15
    payload[7]  = 10;
    payload[15] = 20;
    // At offset 24 (bits_uncomp_len): 11 continuation bytes (0x81) + terminator (0x01)
    for (int i = 0; i < 11; ++i) {
      payload[24 + i] = 0x81;
    }
    payload[35] = 0x01;
    // At offset 36 (bits_comp_len): huge LEB128 value exceeding payload size
    payload[36] = 0xff;
    payload[37] = 0xff;
    payload[38] = 0xff;
    payload[39] = 0x7f;

    uint64_t blen = 8 + payload.size();
    uint8_t hdr[9];
    hdr[0] = btype;
    for (int i = 0; i < 8; ++i) {
      hdr[1 + i] = static_cast<uint8_t>((blen >> ((7 - i) * 8)) & 0xff);
    }
    ofs.write(reinterpret_cast<const char *>(hdr), sizeof(hdr));
    ofs.write(reinterpret_cast<const char *>(payload.data()), payload.size());

    // Append a trailing block header with blen = UINT64_MAX to test overflow protection
    uint8_t overflow_hdr[9] = {btype, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff};
    ofs.write(reinterpret_cast<const char *>(overflow_hdr), sizeof(overflow_hdr));
  }
  auto mres = Execute({malformed_path, "sig"});
  EXPECT_EQ(mres.exit_code, 0);
  EXPECT_EQ(mres.out, "@0 TOP.sig = 0\n");
}

TEST_F(FstQueryTest, ListHierarchyScopesAttributesAndAliases) {
  std::string path = TempFstPath("hierarchy.fst");
  {
    fst::Writer writer(path);
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "top_mod");
    fst::Handle h_clk = writer.createVar(fst::Hierarchy::VarType::VCD_WIRE,
                                         fst::Hierarchy::VarDirection::INPUT, 1, "clk", 0);

    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "core", "core_mod");
    // Enum table + attribute metadata inside hierarchy
    fst::EnumHandle eh = writer.createEnumTable("fsm_state_e", 2,
                                                std::vector<std::pair<const char *, const char *>>{
                                                    {"IDLE", "00"}, {"RUN", "01"}, {"DONE", "10"}});
    writer.emitEnumTableRef(eh);
    fst::Handle h_state =
        writer.createVar(fst::Hierarchy::VarType::SV_ENUM, fst::Hierarchy::VarDirection::IMPLICIT,
                         2, "state [1:0]", 0);

    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "alu", "alu_mod");
    fst::Handle h_pc = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                        fst::Hierarchy::VarDirection::OUTPUT, 32, "pc [31:0]", 0);
    // Alias handle pointing back to TOP.clk
    (void)writer.createVar(fst::Hierarchy::VarType::VCD_WIRE, fst::Hierarchy::VarDirection::INPUT,
                           1, "alu_clk", h_clk);
    writer.upscope();  // exit alu
    writer.upscope();  // exit core
    writer.upscope();  // exit TOP

    writer.emitTimeChange(0);
    writer.emitValueChange(h_clk, uint64_t{0});
    writer.emitValueChange(h_state, uint64_t{0});
    writer.emitValueChange(h_pc, uint64_t{0x1000});
    writer.emitTimeChange(10);
    writer.emitValueChange(h_clk, uint64_t{1});
    writer.close();
  }

  // List all signals (flag after file, no pattern)
  {
    auto res = Execute({path, "--list"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "TOP.clk [1] (handle=1)\n"
              "TOP.core.state [2] (handle=2)\n"
              "TOP.core.alu.pc [32] (handle=3)\n"
              "TOP.core.alu.alu_clk [1] (handle=1)\n");
  }

  // List all signals (flag before file, no pattern)
  {
    auto res = Execute({"--list", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "TOP.clk [1] (handle=1)\n"
              "TOP.core.state [2] (handle=2)\n"
              "TOP.core.alu.pc [32] (handle=3)\n"
              "TOP.core.alu.alu_clk [1] (handle=1)\n");
  }

  // List filtered by pattern (flag before file)
  {
    auto res = Execute({"--list", path, "alu."});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "TOP.core.alu.pc [32] (handle=3)\n"
              "TOP.core.alu.alu_clk [1] (handle=1)\n");
  }

  // List filtered by pattern (flag after pattern)
  {
    auto res = Execute({path, "alu.", "--list"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "TOP.core.alu.pc [32] (handle=3)\n"
              "TOP.core.alu.alu_clk [1] (handle=1)\n");
  }

  // Unmatched pattern returns 0 with empty output
  {
    auto res = Execute({path, "--list", "does_not_exist"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_TRUE(res.out.empty());
  }

  // Querying an alias directly when the primary signal is not matched
  {
    auto res = Execute({"--exact", path, "TOP.core.alu.alu_clk"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@0 TOP.core.alu.alu_clk = 0\n"
              "@10 TOP.core.alu.alu_clk = 1\n");
  }

  // Querying a pattern that matches both primary and alias signals emits both
  {
    auto res = Execute({path, "clk"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@0 TOP.clk = 0\n"
              "@0 TOP.core.alu.alu_clk = 0\n"
              "@10 TOP.clk = 1\n"
              "@10 TOP.core.alu.alu_clk = 1\n");
  }

  // Sampling when both primary and alias signals match emits both
  {
    auto res = Execute({"--sample_at", "10", path, "clk"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@10 (sample) TOP.clk = 1\n"
              "@10 (sample) TOP.core.alu.alu_clk = 1\n");
  }
}

TEST_F(FstQueryTest, SingleMultiAndWideBitTransitions) {
  std::string path = TempFstPath("transitions.fst");
  {
    fst::Writer writer(path);
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
    fst::Handle h_clk = writer.createVar(fst::Hierarchy::VarType::VCD_WIRE,
                                         fst::Hierarchy::VarDirection::IMPLICIT, 1, "clk", 0);
    fst::Handle h_pc  = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                         fst::Hierarchy::VarDirection::IMPLICIT, 32, "pc [31:0]", 0);
    fst::Handle h_wide64 =
        writer.createVar(fst::Hierarchy::VarType::VCD_REG, fst::Hierarchy::VarDirection::IMPLICIT,
                         64, "data64 [63:0]", 0);
    fst::Handle h_wide128 =
        writer.createVar(fst::Hierarchy::VarType::VCD_REG, fst::Hierarchy::VarDirection::IMPLICIT,
                         128, "data128 [127:0]", 0);
    writer.upscope();

    std::string init_128(128, '0');
    init_128[0]   = '1';
    init_128[127] = '1';

    // Emit initial values before first emitTimeChange so fst::Writer populates
    // Section 2 (Initial Bits) directly rather than leaving initial bits as 'z'.
    writer.emitValueChange(h_clk, uint64_t{0});
    writer.emitValueChange(h_pc, uint64_t{0x80000000ULL});
    writer.emitValueChange(h_wide64, uint64_t{0xdeadbeefcafebabeULL});
    writer.emitValueChange(h_wide128, init_128.c_str());
    writer.emitTimeChange(0);

    writer.emitTimeChange(10);
    writer.emitValueChange(h_clk, uint64_t{1});
    writer.emitValueChange(h_pc, uint64_t{0x80000004ULL});

    writer.emitTimeChange(20);
    writer.emitValueChange(h_clk, uint64_t{0});
    writer.emitValueChange(h_wide64, uint64_t{0x123456789abcdef0ULL});
    writer.close();
  }

  auto res = Execute({path, "TOP.clk", "TOP.pc", "TOP.data64"});
  EXPECT_EQ(res.exit_code, 0);
  EXPECT_EQ(res.out,
            "@0 TOP.clk = 0\n"
            "@0 TOP.pc = 0x80000000\n"
            "@0 TOP.data64 = 0xdeadbeefcafebabe\n"
            "@10 TOP.clk = 1\n"
            "@10 TOP.pc = 0x80000004\n"
            "@20 TOP.clk = 0\n"
            "@20 TOP.data64 = 0x123456789abcdef0\n");

  // Query >64-bit signal
  auto res128 = Execute({path, "TOP.data128"});
  EXPECT_EQ(res128.exit_code, 0);
  std::string expected_128(128, '0');
  expected_128[0]   = '1';
  expected_128[127] = '1';
  EXPECT_EQ(res128.out, "@0 TOP.data128 = " + expected_128 + "\n");
}

TEST_F(FstQueryTest, FourStateVerilogValues) {
  std::string path = TempFstPath("four_state.fst");
  {
    fst::Writer writer(path);
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
    fst::Handle h_bit = writer.createVar(fst::Hierarchy::VarType::SV_LOGIC,
                                         fst::Hierarchy::VarDirection::IMPLICIT, 1, "tri_bit", 0);
    fst::Handle h_bus =
        writer.createVar(fst::Hierarchy::VarType::SV_LOGIC, fst::Hierarchy::VarDirection::IMPLICIT,
                         8, "tri_bus [7:0]", 0);
    writer.upscope();

    writer.emitValueChange(h_bit, "z");
    writer.emitValueChange(h_bus, "xxxxzzzz");
    writer.emitTimeChange(0);

    writer.emitTimeChange(5);
    writer.emitValueChange(h_bit, "1");
    writer.emitValueChange(h_bus, "00001111");

    writer.emitTimeChange(10);
    writer.emitValueChange(h_bit, "0");
    writer.emitValueChange(h_bus, "1010xz01");
    writer.close();
  }

  auto res = Execute({path, "tri_"});
  EXPECT_EQ(res.exit_code, 0);
  EXPECT_EQ(res.out,
            "@0 TOP.tri_bit = z\n"
            "@0 TOP.tri_bus = xxxxzzzz\n"
            "@5 TOP.tri_bit = 1\n"
            "@5 TOP.tri_bus = 0xf\n"
            "@10 TOP.tri_bit = 0\n"
            "@10 TOP.tri_bus = 1010xz01\n");
}

TEST_F(FstQueryTest, WaveDeduplicationAndZeroRunPositionEncoding) {
  std::string path = TempFstPath("dedup_pos.fst");
  {
    fst::Writer writer(path);
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
    // Idle signals (never toggle after t=0 -> zero-run in position table)
    fst::Handle h_const0 = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                            fst::Hierarchy::VarDirection::IMPLICIT, 8, "const0", 0);
    fst::Handle h_const1 = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                            fst::Hierarchy::VarDirection::IMPLICIT, 8, "const1", 0);
    // Three signals with identical transition streams (triggers negative back-ref and prev_neg
    // repeat in position table)
    fst::Handle h_dup_a = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                           fst::Hierarchy::VarDirection::IMPLICIT, 8, "dup_a", 0);
    fst::Handle h_dup_b = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                           fst::Hierarchy::VarDirection::IMPLICIT, 8, "dup_b", 0);
    fst::Handle h_dup_c = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                           fst::Hierarchy::VarDirection::IMPLICIT, 8, "dup_c", 0);
    writer.upscope();

    writer.emitValueChange(h_const0, uint64_t{0xaa});
    writer.emitValueChange(h_const1, uint64_t{0x55});
    writer.emitValueChange(h_dup_a, uint64_t{0x01});
    writer.emitValueChange(h_dup_b, uint64_t{0x01});
    writer.emitValueChange(h_dup_c, uint64_t{0x01});
    writer.emitTimeChange(0);

    writer.emitTimeChange(10);
    writer.emitValueChange(h_dup_a, uint64_t{0x22});
    writer.emitValueChange(h_dup_b, uint64_t{0x22});
    writer.emitValueChange(h_dup_c, uint64_t{0x22});

    writer.emitTimeChange(20);
    writer.emitValueChange(h_dup_a, uint64_t{0x33});
    writer.emitValueChange(h_dup_b, uint64_t{0x33});
    writer.emitValueChange(h_dup_c, uint64_t{0x33});
    writer.close();
  }

  auto res = Execute({path, "TOP."});
  EXPECT_EQ(res.exit_code, 0);
  EXPECT_EQ(res.out,
            "@0 TOP.const0 = 0xaa\n"
            "@0 TOP.const1 = 0x55\n"
            "@0 TOP.dup_a = 0x1\n"
            "@0 TOP.dup_b = 0x1\n"
            "@0 TOP.dup_c = 0x1\n"
            "@10 TOP.dup_a = 0x22\n"
            "@10 TOP.dup_b = 0x22\n"
            "@10 TOP.dup_c = 0x22\n"
            "@20 TOP.dup_a = 0x33\n"
            "@20 TOP.dup_b = 0x33\n"
            "@20 TOP.dup_c = 0x33\n");
}

TEST_F(FstQueryTest, MultiBlockAndTimeWindowFiltering) {
  std::string path = TempFstPath("multiblock.fst");
  {
    fst::Writer writer(path);
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
    fst::Handle h_cnt = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                         fst::Hierarchy::VarDirection::IMPLICIT, 16, "cnt", 0);
    writer.upscope();

    // Block 1: t = 0..10
    writer.emitValueChange(h_cnt, uint64_t{0x10});
    writer.emitTimeChange(0);
    writer.emitTimeChange(10);
    writer.emitValueChange(h_cnt, uint64_t{0x20});
    writer.flushValueChangeData();

    // Block 2: t = 20..30 (flushes Block 1 when emitTimeChange(20) is called)
    writer.emitTimeChange(20);
    writer.emitValueChange(h_cnt, uint64_t{0x30});
    writer.emitTimeChange(30);
    writer.emitValueChange(h_cnt, uint64_t{0x40});
    writer.flushValueChangeData();

    // Block 3: t = 40..50
    writer.emitTimeChange(40);
    writer.emitValueChange(h_cnt, uint64_t{0x50});
    writer.emitTimeChange(50);
    writer.emitValueChange(h_cnt, uint64_t{0x60});
    writer.close();
  }

  // Full trace across all 3 wave blocks
  {
    auto res = Execute({path, "cnt"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@0 TOP.cnt = 0x10\n"
              "@10 TOP.cnt = 0x20\n"
              "@20 TOP.cnt = 0x30\n"
              "@30 TOP.cnt = 0x40\n"
              "@40 TOP.cnt = 0x50\n"
              "@50 TOP.cnt = 0x60\n");
  }

  // Window [15, 35] -> only Block 2 events
  {
    auto res = Execute({path, "--start", "15", "--end", "35", "cnt"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@20 TOP.cnt = 0x30\n"
              "@30 TOP.cnt = 0x40\n");
  }

  // Flags before file with '=' syntax
  {
    auto res = Execute({"--start=40", "--end=50", path, "cnt"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@40 TOP.cnt = 0x50\n"
              "@50 TOP.cnt = 0x60\n");
  }

  // Flags after positional arguments
  {
    auto res = Execute({path, "cnt", "--start", "40", "--end", "50"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@40 TOP.cnt = 0x50\n"
              "@50 TOP.cnt = 0x60\n");
  }

  // Inverted time window (--start > --end) fails with error
  {
    auto res = Execute({path, "cnt", "--start", "40", "--end", "20"});
    EXPECT_EQ(res.exit_code, 1);
    EXPECT_NE(res.err.find("Invalid time range: --start (40) is greater than --end (20)"),
              std::string::npos);
  }
}

TEST_F(FstQueryTest, UncompressedWaveDataPackType) {
  std::string path = TempFstPath("no_compression.fst");
  {
    fst::Writer writer(path);
    writer.setWriterPackType(fst::WriterPackType::NO_COMPRESSION);
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
    fst::Handle h_sig = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                         fst::Hierarchy::VarDirection::IMPLICIT, 8, "sig", 0);
    writer.upscope();

    writer.emitValueChange(h_sig, uint64_t{0x11});
    writer.emitTimeChange(0);
    writer.emitTimeChange(100);
    writer.emitValueChange(h_sig, uint64_t{0x22});
    writer.close();
  }

  auto res = Execute({path, "sig"});
  EXPECT_EQ(res.exit_code, 0);
  EXPECT_EQ(res.out,
            "@0 TOP.sig = 0x11\n"
            "@100 TOP.sig = 0x22\n");
}

TEST_F(FstQueryTest, InfoMetadataDiscovery) {
  std::string path = TempFstPath("metadata.fst");
  {
    fst::Writer writer(path);
    writer.setTimecale(-12);  // 1 ps
    writer.setWriter("Verilator 5.028");
    writer.setDate();
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
    fst::Handle h_sig1 = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                          fst::Hierarchy::VarDirection::IMPLICIT, 1, "sig1", 0);
    fst::Handle h_sig2 = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                          fst::Hierarchy::VarDirection::IMPLICIT, 32, "sig2", 0);
    writer.upscope();
    writer.emitValueChange(h_sig1, uint64_t{0});
    writer.emitValueChange(h_sig2, uint64_t{0});
    writer.emitTimeChange(100);
    writer.emitTimeChange(500);
    writer.emitValueChange(h_sig1, uint64_t{1});
    writer.close();
  }

  auto res = Execute({"--info", path});
  EXPECT_EQ(res.exit_code, 0);
  EXPECT_NE(res.out.find("File:         " + path), std::string::npos);
  EXPECT_NE(res.out.find("Writer:       Verilator 5.028"), std::string::npos);
  EXPECT_NE(res.out.find("Date:         "), std::string::npos);
  EXPECT_EQ(res.out.find("\n\n"), std::string::npos);
  EXPECT_NE(res.out.find("Timescale:    1 ps (1e-12 s)"), std::string::npos);
  EXPECT_NE(res.out.find("Time Range:   100 to 500 ps"), std::string::npos);
  EXPECT_NE(res.out.find("Scopes:       1"), std::string::npos);
  EXPECT_NE(res.out.find("Signals:      2"), std::string::npos);
  EXPECT_EQ(res.out.find("Wave Blocks"), std::string::npos);

  // Sampling before trace start_time (50 < 100) outputs 'x', while sampling at 100 outputs initial
  {
    auto sres = Execute({"--sample_at", "50,100", path});
    EXPECT_EQ(sres.exit_code, 0);
    EXPECT_EQ(sres.out,
              "@50 (sample) TOP.sig1 = x\n"
              "@50 (sample) TOP.sig2 = x\n"
              "@100 (sample) TOP.sig1 = 0\n"
              "@100 (sample) TOP.sig2 = 0x0\n");
  }

  // Test different timescale formats (e.g. 1 ns)
  {
    std::string ns_path = TempFstPath("metadata_ns.fst");
    {
      fst::Writer writer(ns_path);
      writer.setTimecale(-9);  // 1 ns
      writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
      fst::Handle h_sig = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                           fst::Hierarchy::VarDirection::IMPLICIT, 1, "sig", 0);
      writer.upscope();
      writer.emitValueChange(h_sig, uint64_t{0});
      writer.emitTimeChange(10);
      writer.emitTimeChange(20);
      writer.close();
    }
    auto ns_res = Execute({"--info", ns_path});
    EXPECT_EQ(ns_res.exit_code, 0);
    EXPECT_NE(ns_res.out.find("Timescale:    1 ns (1e-9 s)"), std::string::npos);
    EXPECT_NE(ns_res.out.find("Time Range:   10 to 20 ns"), std::string::npos);
  }

  // Test non-unit timescale multiplier (-11 -> 10 ps) and out-of-range exponent (-16 -> 1e-16 s)
  {
    std::string ps10_path = TempFstPath("metadata_10ps.fst");
    {
      fst::Writer writer(ps10_path);
      writer.setTimecale(-11);  // 10 ps
      writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
      fst::Handle h_sig = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                           fst::Hierarchy::VarDirection::IMPLICIT, 1, "sig", 0);
      writer.upscope();
      writer.emitValueChange(h_sig, uint64_t{0});
      writer.emitTimeChange(5);
      writer.emitTimeChange(15);
      writer.close();
    }
    auto ps10_res = Execute({"--info", ps10_path});
    EXPECT_EQ(ps10_res.exit_code, 0);
    EXPECT_NE(ps10_res.out.find("Timescale:    10 ps (1e-11 s)"), std::string::npos);
    EXPECT_NE(ps10_res.out.find("Time Range:   5 to 15 ticks (50 to 150 ps)"), std::string::npos);

    std::string e16_path = TempFstPath("metadata_e16.fst");
    {
      fst::Writer writer(e16_path);
      writer.setTimecale(-16);
      writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
      fst::Handle h_sig = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                           fst::Hierarchy::VarDirection::IMPLICIT, 1, "sig", 0);
      writer.upscope();
      writer.emitValueChange(h_sig, uint64_t{0});
      writer.emitTimeChange(1);
      writer.emitTimeChange(2);
      writer.close();
    }
    auto e16_res = Execute({"--info", e16_path});
    EXPECT_EQ(e16_res.exit_code, 0);
    EXPECT_NE(e16_res.out.find("Timescale:    1e-16 s"), std::string::npos);
  }
}

TEST_F(FstQueryTest, DefaultLimitAndTruncationNotice) {
  std::string path = TempFstPath("limit_test.fst");
  {
    fst::Writer writer(path);
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
    fst::Handle h_clk = writer.createVar(fst::Hierarchy::VarType::VCD_WIRE,
                                         fst::Hierarchy::VarDirection::IMPLICIT, 1, "clk", 0);
    writer.upscope();
    for (uint64_t t = 0; t < 20; ++t) {
      writer.emitTimeChange(t * 10);
      writer.emitValueChange(h_clk, t % 2);
    }
    writer.close();
  }

  // With default limit (1000): 20 events < 1000, so no truncation notice
  {
    auto res = Execute({path, "clk"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_TRUE(res.err.empty());
    size_t count = 0;
    for (size_t pos = 0; (pos = res.out.find("@", pos)) != std::string::npos; ++pos)
      count++;
    EXPECT_EQ(count, 20);
  }

  // With --limit 5: output capped at 5 with explicit truncation notice on stderr
  {
    auto res = Execute({"--limit", "5", path, "clk"});
    EXPECT_EQ(res.exit_code, 0);
    size_t count = 0;
    for (size_t pos = 0; (pos = res.out.find("@", pos)) != std::string::npos; ++pos)
      count++;
    EXPECT_EQ(count, 5);
    EXPECT_NE(
        res.err.find("[fst_query: Output limited to 5 transitions. Use --limit 0 for unlimited"),
        std::string::npos);
  }

  // With --limit 0: unlimited output, no truncation notice
  {
    auto res = Execute({"--limit", "0", path, "clk"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_TRUE(res.err.empty());
    size_t count = 0;
    for (size_t pos = 0; (pos = res.out.find("@", pos)) != std::string::npos; ++pos)
      count++;
    EXPECT_EQ(count, 20);
  }
}

TEST_F(FstQueryTest, TailAndCountModes) {
  std::string path = TempFstPath("tail_count.fst");
  {
    fst::Writer writer(path);
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
    fst::Handle h_val = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                         fst::Hierarchy::VarDirection::IMPLICIT, 8, "val", 0);
    writer.upscope();
    writer.emitTimeChange(10);
    writer.emitValueChange(h_val, uint64_t{1});
    writer.emitTimeChange(20);
    writer.emitValueChange(h_val, uint64_t{2});
    writer.emitTimeChange(30);
    writer.emitValueChange(h_val, uint64_t{3});
    writer.emitTimeChange(40);
    writer.emitValueChange(h_val, uint64_t{4});
    writer.emitTimeChange(50);
    writer.emitValueChange(h_val, uint64_t{5});
    writer.close();
  }

  // --count mode (5 toggles at t=10..50 = 5 transitions)
  {
    auto res = Execute({"--count", path, "val"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out, "5 transitions\n");
    EXPECT_TRUE(res.err.empty());
  }

  // --count mode with no matching signals outputs '0 transitions'
  {
    auto res = Execute({"--count", path, "nonexistent_signal"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out, "0 transitions\n");
    EXPECT_TRUE(res.err.empty());
  }

  // --tail 2 mode (should only output t=40 and t=50)
  {
    auto res = Execute({"--tail", "2", path, "val"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@40 TOP.val = 0x4\n"
              "@50 TOP.val = 0x5\n");
  }
}

TEST_F(FstQueryTest, SampleAtInstantaneousState) {
  std::string path = TempFstPath("sample_test.fst");
  {
    fst::Writer writer(path);
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
    fst::Handle h_rst = writer.createVar(fst::Hierarchy::VarType::VCD_WIRE,
                                         fst::Hierarchy::VarDirection::IMPLICIT, 1, "rst_n", 0);
    fst::Handle h_pc  = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                         fst::Hierarchy::VarDirection::IMPLICIT, 32, "pc", 0);
    writer.upscope();

    // Initial state: rst_n = 1, pc = 0x80000000
    writer.emitValueChange(h_rst, uint64_t{1});
    writer.emitValueChange(h_pc, uint64_t{0x80000000});
    writer.emitTimeChange(0);

    // Only pc toggles at t=10 and t=20; rst_n never toggles again!
    writer.emitTimeChange(10);
    writer.emitValueChange(h_pc, uint64_t{0x80000004});
    writer.emitTimeChange(20);
    writer.emitValueChange(h_pc, uint64_t{0x80000008});
    writer.close();
  }

  // Sample at t=15 (between 10 and 20):
  // pc should be 0x80000004; rst_n should still be 1 despite zero toggles!
  {
    auto res = Execute({"--sample_at", "15", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@15 (sample) TOP.rst_n = 1\n"
              "@15 (sample) TOP.pc = 0x80000004\n");
  }

  // Sample at t=25 (after 20):
  // pc should be 0x80000008; rst_n should still be 1
  {
    auto res = Execute({"--sample_at", "25", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@25 (sample) TOP.rst_n = 1\n"
              "@25 (sample) TOP.pc = 0x80000008\n");
  }
}

TEST_F(FstQueryTest, ScopeAndDepthFiltering) {
  std::string path = TempFstPath("scope_test.fst");
  {
    fst::Writer writer(path);
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");

    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "core", "");
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "alu", "");
    (void)writer.createVar(fst::Hierarchy::VarType::VCD_REG, fst::Hierarchy::VarDirection::IMPLICIT,
                           32, "res", 0);
    writer.upscope();  // exit alu

    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "rf", "");
    (void)writer.createVar(fst::Hierarchy::VarType::VCD_REG, fst::Hierarchy::VarDirection::IMPLICIT,
                           32, "r0", 0);
    writer.upscope();  // exit rf
    writer.upscope();  // exit core

    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "io", "");
    (void)writer.createVar(fst::Hierarchy::VarType::VCD_WIRE,
                           fst::Hierarchy::VarDirection::IMPLICIT, 1, "gpio", 0);
    writer.upscope();  // exit io

    // Signal in parent scope TOP with same name as child scope TOP.core
    (void)writer.createVar(fst::Hierarchy::VarType::VCD_WIRE,
                           fst::Hierarchy::VarDirection::IMPLICIT, 1, "core", 0);
    writer.upscope();  // exit TOP

    writer.emitTimeChange(0);
    writer.close();
  }

  // --scope TOP.core (and trailing dot --scope TOP.core.) should not match signal TOP.core
  {
    auto res = Execute({"--list", "--scope", "TOP.core", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "TOP.core.alu.res [32] (handle=1)\n"
              "TOP.core.rf.r0 [32] (handle=2)\n");

    auto res_dot = Execute({"--list", "--scope", "TOP.core.", path});
    EXPECT_EQ(res_dot.exit_code, 0);
    EXPECT_EQ(res_dot.out, res.out);
  }

  // --scopes_only
  {
    auto res = Execute({"--list", "--scopes_only", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "TOP\n"
              "TOP.core\n"
              "TOP.core.alu\n"
              "TOP.core.rf\n"
              "TOP.io\n");
  }

  // --scope TOP.core --scopes_only
  {
    auto res = Execute({"--list", "--scope", "TOP.core", "--scopes_only", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "TOP.core\n"
              "TOP.core.alu\n"
              "TOP.core.rf\n");
  }

  // --scopes_only --depth 2: only TOP and 1 level of submodules (TOP.core, TOP.io)
  {
    auto res = Execute({"--list", "--scopes_only", "--depth", "2", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "TOP\n"
              "TOP.core\n"
              "TOP.io\n");
  }

  // --scope TOP --depth 1 --scopes_only: TOP and direct submodules TOP.core, TOP.io
  {
    auto res = Execute({"--list", "--scope", "TOP", "--depth", "1", "--scopes_only", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "TOP\n"
              "TOP.core\n"
              "TOP.io\n");
  }

  // --scope TOP.core --depth 1 (signals): TOP.core has no direct signals (only in child scopes)
  {
    auto res = Execute({"--list", "--scope", "TOP.core", "--depth", "1", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_TRUE(res.out.empty());
  }

  // --scope TOP.core --depth 2 (signals): signals in direct child scopes of TOP.core
  {
    auto res = Execute({"--list", "--scope", "TOP.core", "--depth", "2", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "TOP.core.alu.res [32] (handle=1)\n"
              "TOP.core.rf.r0 [32] (handle=2)\n");
  }

  // --scope TOP.core.alu --depth 1 (signals): direct signals of TOP.core.alu
  {
    auto res = Execute({"--list", "--scope", "TOP.core.alu", "--depth", "1", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out, "TOP.core.alu.res [32] (handle=1)\n");
  }
}

TEST_F(FstQueryTest, RegexAndExactPatternMatching) {
  std::string path = TempFstPath("regex_test.fst");
  {
    fst::Writer writer(path);
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "core", "");
    (void)writer.createVar(fst::Hierarchy::VarType::VCD_REG, fst::Hierarchy::VarDirection::IMPLICIT,
                           32, "pc", 0);
    (void)writer.createVar(fst::Hierarchy::VarType::VCD_REG, fst::Hierarchy::VarDirection::IMPLICIT,
                           32, "upcount", 0);
    (void)writer.createVar(fst::Hierarchy::VarType::VCD_REG, fst::Hierarchy::VarDirection::IMPLICIT,
                           32, "instruction", 0);
    writer.upscope();
    writer.upscope();
    writer.emitTimeChange(0);
    writer.close();
  }

  // Default substring: 'pc' matches both 'TOP.core.pc' and 'TOP.core.upcount'
  {
    auto res = Execute({"--list", path, "pc"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "TOP.core.pc [32] (handle=1)\n"
              "TOP.core.upcount [32] (handle=2)\n");
  }

  // --exact: 'TOP.core.pc' matches only 'TOP.core.pc'
  {
    auto res = Execute({"--list", "--exact", path, "TOP.core.pc"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out, "TOP.core.pc [32] (handle=1)\n");
  }

  // --regex: 'TOP\\.core\\.(pc|instruction)' matches pc and instruction
  {
    auto res = Execute({"--list", "--regex", path, "TOP\\.core\\.(pc|instruction)"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "TOP.core.pc [32] (handle=1)\n"
              "TOP.core.instruction [32] (handle=3)\n");
  }

  // Invalid regex fails with rc=1
  {
    auto res = Execute({"--list", "--regex", path, "[unclosed_regex"});
    EXPECT_EQ(res.exit_code, 1);
    EXPECT_NE(res.err.find("Invalid regular expression"), std::string::npos);
  }
}

TEST_F(FstQueryTest, SampleAtMultipleTimestamps) {
  std::string path = TempFstPath("multi_sample_test.fst");
  {
    fst::Writer writer(path);
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
    fst::Handle h_rst = writer.createVar(fst::Hierarchy::VarType::VCD_WIRE,
                                         fst::Hierarchy::VarDirection::IMPLICIT, 1, "rst_n", 0);
    fst::Handle h_pc  = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                         fst::Hierarchy::VarDirection::IMPLICIT, 32, "pc", 0);
    writer.upscope();

    writer.emitValueChange(h_rst, uint64_t{1});
    writer.emitValueChange(h_pc, uint64_t{0x80000000});
    writer.emitTimeChange(0);

    writer.emitTimeChange(10);
    writer.emitValueChange(h_pc, uint64_t{0x80000004});
    writer.emitTimeChange(20);
    writer.emitValueChange(h_pc, uint64_t{0x80000008});
    writer.emitTimeChange(30);
    writer.emitValueChange(h_pc, uint64_t{0x8000000c});
    writer.close();
  }

  // Multi-timestamp sampling: 15 and 25 in single pass
  {
    auto res = Execute({"--sample_at", "15,25", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@15 (sample) TOP.rst_n = 1\n"
              "@15 (sample) TOP.pc = 0x80000004\n"
              "@25 (sample) TOP.rst_n = 1\n"
              "@25 (sample) TOP.pc = 0x80000008\n");
  }

  // Comma-separated with spaces and out-of-order sorting: "25, 15" -> ordered chronologically
  {
    auto res = Execute({"--sample_at", "25, 15", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@15 (sample) TOP.rst_n = 1\n"
              "@15 (sample) TOP.pc = 0x80000004\n"
              "@25 (sample) TOP.rst_n = 1\n"
              "@25 (sample) TOP.pc = 0x80000008\n");
  }

  // Deduplication: "15,15,25" outputs 15 and 25 exactly once
  {
    auto res = Execute({"--sample_at", "15,15,25", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@15 (sample) TOP.rst_n = 1\n"
              "@15 (sample) TOP.pc = 0x80000004\n"
              "@25 (sample) TOP.rst_n = 1\n"
              "@25 (sample) TOP.pc = 0x80000008\n");
  }

  // Multi-timestamp with signal filter
  {
    auto res = Execute({"--sample_at", "15,25", path, "pc"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@15 (sample) TOP.pc = 0x80000004\n"
              "@25 (sample) TOP.pc = 0x80000008\n");
  }

  // Invalid timestamp fails with rc=1
  {
    auto res = Execute({"--sample_at", "15,invalid", path});
    EXPECT_EQ(res.exit_code, 1);
    EXPECT_NE(res.err.find("Invalid --sample_at timestamp"), std::string::npos);

    auto neg_res = Execute({"--sample_at", "15,-1", path});
    EXPECT_EQ(neg_res.exit_code, 1);
    EXPECT_NE(neg_res.err.find("Invalid --sample_at timestamp"), std::string::npos);
  }
}

TEST_F(FstQueryTest, FstSessionReuse) {
  std::string path = TempFstPath("session_reuse_test.fst");
  {
    fst::Writer writer(path);
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
    fst::Handle h_rst = writer.createVar(fst::Hierarchy::VarType::VCD_WIRE,
                                         fst::Hierarchy::VarDirection::IMPLICIT, 1, "rst_n", 0);
    fst::Handle h_pc  = writer.createVar(fst::Hierarchy::VarType::VCD_REG,
                                         fst::Hierarchy::VarDirection::IMPLICIT, 32, "pc", 0);
    writer.upscope();

    writer.emitValueChange(h_rst, uint64_t{1});
    writer.emitValueChange(h_pc, uint64_t{0x80000000});
    writer.emitTimeChange(0);
    writer.emitTimeChange(10);
    writer.emitValueChange(h_pc, uint64_t{0x80000004});
    writer.close();
  }

  auto session_status = FstSession::Open(path);
  ASSERT_TRUE(session_status.ok());
  auto &session = *session_status;

  const auto &meta = session->GetHeaderMetadata();
  EXPECT_EQ(meta.file_path, path);
  EXPECT_EQ(meta.num_vars, 2);
  EXPECT_EQ(session->GetAllSignals().size(), 2);
  EXPECT_EQ(session->GetAllScopes().size(), 1);

  // Run Query 1: --list
  {
    std::ostringstream out;
    std::ostringstream err;
    int rc = session->RunQuery("--list", out, err);
    EXPECT_EQ(rc, 0);
    EXPECT_EQ(out.str(),
              "TOP.rst_n [1] (handle=1)\n"
              "TOP.pc [32] (handle=2)\n");
  }

  // Run Query 2: --sample_at 10
  {
    std::ostringstream out;
    std::ostringstream err;
    int rc = session->RunQuery("--sample_at 10 pc", out, err);
    EXPECT_EQ(rc, 0);
    EXPECT_EQ(out.str(), "@10 (sample) TOP.pc = 0x80000004\n");
  }

  // Run Query 3: signal transitions
  {
    std::ostringstream out;
    std::ostringstream err;
    int rc = session->RunQuery("pc", out, err);
    EXPECT_EQ(rc, 0);
    EXPECT_EQ(out.str(),
              "@0 TOP.pc = 0x80000000\n"
              "@10 TOP.pc = 0x80000004\n");
  }
}

TEST_F(FstQueryTest, BatchModeStreamAndFile) {
  std::string path = TempFstPath("batch_test.fst");
  {
    fst::Writer writer(path);
    writer.setTimecale(-12);
    writer.setWriter("BatchTestWriter");
    writer.setScope(fst::Hierarchy::ScopeType::VCD_MODULE, "TOP", "");
    fst::Handle h_clk = writer.createVar(fst::Hierarchy::VarType::VCD_WIRE,
                                         fst::Hierarchy::VarDirection::IMPLICIT, 1, "clk", 0);
    writer.upscope();
    writer.emitValueChange(h_clk, uint64_t{0});
    writer.emitTimeChange(0);
    writer.emitTimeChange(10);
    writer.emitValueChange(h_clk, uint64_t{1});
    writer.emitTimeChange(20);
    writer.emitValueChange(h_clk, uint64_t{0});
    writer.close();
  }

  // In-stream batch via session->RunBatch
  {
    auto session_status = FstSession::Open(path);
    ASSERT_TRUE(session_status.ok());
    auto &session = *session_status;

    std::istringstream input(
        "# Batch query test\n"
        "\n"
        "--info\n"
        "--sample_at 10 clk\n"
        "exit\n"
        "--sample_at 20 clk\n");

    std::ostringstream out;
    std::ostringstream err;
    int rc = session->RunBatch(input, out, err);
    EXPECT_EQ(rc, 0);
    std::string result = out.str();

    // Verify info output is present
    EXPECT_NE(result.find("Writer:       BatchTestWriter"), std::string::npos);
    EXPECT_NE(result.find("--- [query end] ---"), std::string::npos);

    // Verify sample output is present
    EXPECT_NE(result.find("@10 (sample) TOP.clk = 1"), std::string::npos);

    // Verify commands after exit were not executed
    EXPECT_EQ(result.find("@20 (sample)"), std::string::npos);
  }

  // CLI execution via --batch <file>
  {
    std::string batch_path = TempFstPath("test_cmds.batch");
    {
      std::ofstream bofs(batch_path);
      bofs << "--list\n";
      bofs << "--count clk\n";
    }

    auto res = Execute({"--batch", batch_path, path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_NE(res.out.find("TOP.clk [1] (handle=1)\n--- [query end] ---\n"), std::string::npos);
    EXPECT_NE(res.out.find("3 transitions\n--- [query end] ---\n"), std::string::npos);
  }

  // Nonexistent batch file
  {
    auto res = Execute({"--batch", "nonexistent_batch_file.batch", path});
    EXPECT_EQ(res.exit_code, 1);
    EXPECT_NE(res.err.find("Failed to open batch query file"), std::string::npos);
  }

  // Batch stream with failing query or unknown flag propagates non-zero exit status without exit()
  {
    auto session_status = FstSession::Open(path);
    ASSERT_TRUE(session_status.ok());
    auto &session = *session_status;

    std::istringstream input(
        "--regex [unclosed\n"
        "--unknown_flag\n"
        "--limit abc\n"
        "--batch nested.txt\n"
        "--scope \"\" --list\n");
    std::ostringstream out;
    std::ostringstream err;
    int rc = session->RunBatch(input, out, err);
    EXPECT_EQ(rc, 1);
    EXPECT_NE(err.str().find("Invalid regular expression"), std::string::npos);
    EXPECT_NE(err.str().find("Unknown flag"), std::string::npos);
    EXPECT_NE(err.str().find("Invalid value 'abc' for flag --limit"), std::string::npos);
    EXPECT_NE(err.str().find("Flag '--batch' is not supported inside a session or batch query"),
              std::string::npos);
    EXPECT_NE(out.str().find("TOP.clk [1] (handle=1)"), std::string::npos);
  }
}

TEST_F(FstQueryTest, RealVerilatorSimulationTrace) {
  std::string sim_bin = FindRunfile("tests/verilator_sim/core_mini_axi_sim");
  std::string elf_bin = FindRunfile("tests/cocotb/math.elf");
  ASSERT_TRUE(std::filesystem::exists(sim_bin)) << "Simulator not found at: " << sim_bin;
  ASSERT_TRUE(std::filesystem::exists(elf_bin)) << "Test ELF not found at: " << elf_bin;

  // Generate trace dynamically at test time by running core_mini_axi_sim with math.elf.
  std::string path = TempFstPath("core_mini_axi_sim.fst");

  std::string cmd =
      absl::StrCat("ASAN_OPTIONS=detect_leaks=0 ", sim_bin, " --binary=", elf_bin,
                   " --trace --trace_file=", path, " --backdoor_load --cycles=50 > /dev/null 2>&1");
  int sim_status = std::system(cmd.c_str());
  ASSERT_EQ(sim_status, 0) << "Failed to run simulation command: " << cmd;
  ASSERT_TRUE(std::filesystem::exists(path)) << "Expected trace was not produced at: " << path;

  // 1. Check metadata of real simulation trace
  {
    auto res = Execute({"--info", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_NE(res.out.find("Writer:       Generated by VerilatedFst"), std::string::npos);
    EXPECT_NE(res.out.find("Timescale:    1 s (1e0 s)"), std::string::npos);
    EXPECT_NE(res.out.find("Time Range:   0 to 92 s"), std::string::npos);
    EXPECT_TRUE(re2::RE2::PartialMatch(res.out, R"(Scopes:\s+[1-9]\d*)"));
    EXPECT_TRUE(
        re2::RE2::PartialMatch(res.out, R"(Signals:\s+[1-9]\d*\s+\(unique handles:\s+[1-9]\d*\))"));
  }

  // 2. Count transitions on real clock signal
  {
    auto res = Execute({"--exact", "--count", path, "VCoreMiniAxi.core.CoreMiniAxi.io_aclk"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out, "93 transitions\n");
  }

  // 3. Tail query on clock transitions
  {
    auto res = Execute({"--exact", "--tail", "3", path, "VCoreMiniAxi.core.CoreMiniAxi.io_aclk"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@90 VCoreMiniAxi.core.CoreMiniAxi.io_aclk = 0\n"
              "@91 VCoreMiniAxi.core.CoreMiniAxi.io_aclk = 1\n"
              "@92 VCoreMiniAxi.core.CoreMiniAxi.io_aclk = 0\n");
  }

  // 4. Sample instantaneous state across checkpoints
  {
    auto res =
        Execute({"--exact", "--sample_at", "45,90", path, "VCoreMiniAxi.core.CoreMiniAxi.io_aclk"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_EQ(res.out,
              "@45 (sample) VCoreMiniAxi.core.CoreMiniAxi.io_aclk = 1\n"
              "@90 (sample) VCoreMiniAxi.core.CoreMiniAxi.io_aclk = 0\n");
  }

  // 5. Scopes navigation in real hierarchy
  {
    auto res =
        Execute({"--list", "--scopes_only", "--scope", "VCoreMiniAxi.core", "--depth", "1", path});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_NE(res.out.find("VCoreMiniAxi.core.CoreMiniAxi\n"), std::string::npos);
    EXPECT_NE(res.out.find("VCoreMiniAxi.core.fpnew_pkg\n"), std::string::npos);
  }

  // 6. Regex search across signals with limit guardrail
  {
    auto res = Execute({"--regex", "--limit", "5", path, "io_aclk|io_aresetn"});
    EXPECT_EQ(res.exit_code, 0);
    EXPECT_NE(res.err.find("[fst_query: Output limited to 5 transitions"), std::string::npos);
  }
}

}  // namespace
}  // namespace fst_query
