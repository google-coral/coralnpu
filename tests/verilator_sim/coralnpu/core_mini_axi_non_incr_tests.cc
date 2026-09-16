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

#include <thread>

#include "absl/flags/parse.h"
#include "absl/log/initialize.h"
#include "tests/verilator_sim/coralnpu/core_mini_axi_tb.h"

/* clang-format off */
#include "traffic-generators/traffic-desc.h"
#include "tests/test-modules/utils.h"
/* clang-format on */

extern "C" int sc_main(int argc, char **argv) {
  absl::InitializeLog();
  auto args     = absl::ParseCommandLine(argc, argv);
  int v_argc    = args.size();
  char **v_argv = &args[0];
  Verilated::commandArgs(v_argc, v_argv);

  CoreMiniAxi_tb tb("CoreMiniAxi_tb", 1000000, /* random= */ false,
                    /*debug_axi=*/true, /*instr_trace=*/false,
                    /*backdoor_load=*/false,
                    /*wfi_cb=*/std::nullopt, std::nullopt);

  std::thread sc_main_thread([&tb]() { tb.start(); });

  DataTransfer wrap_write, wrap_read;
  /* WRAP */
  static const uint8_t initial_data[]    = {0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad,
                                            0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad,
                                            0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad,
                                            0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xab, 0xac, 0xad};
  static const uint8_t wrap_write_data[] = {0x81, 0x82, 0x83, 0x84, 0x71, 0x72, 0x73, 0x74,
                                            0x91, 0x92, 0x93, 0x94, 0x81, 0x82, 0x83, 0x84,
                                            0xa1, 0xa2, 0xa3, 0xa4, 0x91, 0x92, 0x93, 0x94,
                                            0xb1, 0xb2, 0xb3, 0xb4, 0xa1, 0xa2, 0xa3, 0xa4};

  wrap_write.addr                 = 0x0;
  wrap_write.cmd                  = DataTransfer::WRITE;
  wrap_write.data                 = wrap_write_data;
  wrap_write.byte_enable          = nullptr;
  wrap_write.length               = 32;
  wrap_write.streaming_width      = 32;
  wrap_write.ext.gen_attr.enabled = true;
  wrap_write.ext.gen_attr.wrap    = true;

  wrap_read.addr                 = 0x0;
  wrap_read.cmd                  = DataTransfer::READ;
  wrap_read.byte_enable          = nullptr;
  wrap_read.length               = 32;
  wrap_read.streaming_width      = 32;
  wrap_read.ext.gen_attr.enabled = true;
  wrap_read.ext.gen_attr.wrap    = true;

  auto wrap_transfer = std::vector<DataTransfer>({
      utils::Write(0, initial_data, 32),
      wrap_write,
      wrap_read,
      utils::Expect(wrap_write_data, 32),
  });

  tb.EnqueueTransactionSync(wrap_transfer);

  uint32_t dummy_data = 0x1234abcd;
  DataTransfer write32;
  write32.addr                     = 0;
  write32.cmd                      = DataTransfer::WRITE;
  write32.data                     = reinterpret_cast<uint8_t *>(&dummy_data);
  write32.length                   = 4;
  write32.byte_enable              = nullptr;
  write32.byte_enable_length       = 0;
  write32.streaming_width          = 4;
  write32.ext.gen_attr.enabled     = true;
  write32.ext.gen_attr.burst_width = 4;

  DataTransfer read32;
  read32.addr                     = 0;
  read32.cmd                      = DataTransfer::READ;
  read32.data                     = reinterpret_cast<uint8_t *>(&dummy_data);
  read32.length                   = 4;
  read32.byte_enable              = nullptr;
  read32.byte_enable_length       = 0;
  read32.streaming_width          = 4;
  read32.ext.gen_attr.enabled     = true;
  read32.ext.gen_attr.burst_width = 4;

  std::vector<DataTransfer> narrow_transfers;
  narrow_transfers.push_back(write32);
  narrow_transfers.push_back(read32);
  narrow_transfers.push_back(utils::Expect(reinterpret_cast<uint8_t *>(&dummy_data), 4));

  write32.addr = 4;
  read32.addr  = 4;
  narrow_transfers.push_back(write32);
  narrow_transfers.push_back(read32);
  narrow_transfers.push_back(utils::Expect(reinterpret_cast<uint8_t *>(&dummy_data), 4));

  write32.addr = 8;
  read32.addr  = 8;
  narrow_transfers.push_back(write32);
  narrow_transfers.push_back(read32);
  narrow_transfers.push_back(utils::Expect(reinterpret_cast<uint8_t *>(&dummy_data), 4));
  tb.EnqueueTransactionSync(utils::merge(narrow_transfers));

  sc_stop();
  sc_main_thread.join();

  return 0;
}
