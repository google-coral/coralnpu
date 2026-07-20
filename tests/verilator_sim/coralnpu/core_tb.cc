// Copyright 2023 Google LLC
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

#define STRINGIZE(x)        #x
#define STR(x)              STRINGIZE(x)
#define CONCAT_HELPER(a, b) a##b
#define CONCAT(a, b)        CONCAT_HELPER(a, b)

#define MODEL_HEADER STR(VERILATOR_MODEL.h)
#include MODEL_HEADER

// clang-format off
#define PARAMS_HEADER STR(hdl/chisel/src/coralnpu/CONCAT(VERILATOR_MODEL, _parameters.h))
// clang-format on
#include PARAMS_HEADER

#include "absl/flags/flag.h"
#include "absl/flags/parse.h"
#include "absl/flags/usage.h"
#include "tests/verilator_sim/coralnpu/coralnpu_cfg.h"
#include "tests/verilator_sim/coralnpu/core_if.h"
#include "tests/verilator_sim/coralnpu/debug_if.h"
#include "tests/verilator_sim/sysc_tb.h"
#include "tests/verilator_sim/util.h"

ABSL_FLAG(int, cycles, 100000000, "Simulation cycles");
ABSL_FLAG(bool, trace, false, "Dump VCD trace");

struct Core_tb : Sysc_tb {
  sc_in<bool> io_halted;
  sc_in<bool> io_fault;
  sc_in<bool> io_ebus_dbus_valid;
  sc_in<sc_bv<KP_lsuAddrBits>> io_ebus_dbus_addr;
  sc_out<bool> io_ebus_fault_valid;
  sc_out<bool> io_ebus_dbus_ready;
  sc_out<sc_bv<KP_programCounterBits>> io_ebus_fault_bits_addr;

  using Sysc_tb::Sysc_tb;  // constructor

  void posedge() {
    check(!io_fault, "io_fault");
    if (io_ebus_dbus_valid) {
      io_ebus_fault_valid     = true;
      io_ebus_dbus_ready      = true;
      io_ebus_fault_bits_addr = io_ebus_dbus_addr;
    } else {
      io_ebus_fault_valid = false;
    }
    if (io_halted)
      sc_stop();
  }
};

static void Core_run(const char *name, const char *bin, const int cycles, const bool trace) {
  VERILATOR_MODEL core(name);
  Core_tb tb("Core_tb", cycles, /* random= */ false);
  Core_if mif("Core_if", bin);
  Debug_if dbg("Debug_if", &mif);

  sc_signal<bool> io_halted;
  sc_signal<bool> io_fault;
  sc_signal<bool> io_wfi;
  sc_signal<bool> io_irq;
  sc_signal<bool> io_debug_req;
  sc_signal<bool> io_ibus_valid;
  sc_signal<bool> io_ibus_ready;
  sc_signal<bool> io_ibus_fault_valid;
  sc_signal<bool> io_ibus_fault_bits_write;
  sc_signal<bool> io_dbus_valid;
  sc_signal<bool> io_dbus_ready;
  sc_signal<bool> io_dbus_write;
  sc_signal<bool> io_ebus_dbus_valid;
  sc_signal<bool> io_ebus_dbus_ready;
  sc_signal<bool> io_ebus_dbus_write;
  sc_signal<bool> io_ebus_fault_valid;
  sc_signal<bool> io_ebus_fault_bits_write;
  sc_signal<bool> io_iflush_valid;
  sc_signal<sc_bv<KP_programCounterBits>> io_iflush_pcNext;
  sc_signal<bool> io_iflush_ready;
  sc_signal<bool> io_dflush_valid;
  sc_signal<bool> io_dflush_ready;
  sc_signal<bool> io_dflush_all;
  sc_signal<bool> io_dflush_clean;
  sc_signal<sc_bv<KP_xlen>> io_csr_in_value_0;
  sc_signal<sc_bv<KP_xlen>> io_csr_in_value_1;
  sc_signal<sc_bv<KP_xlen>> io_csr_in_value_2;
  sc_signal<sc_bv<KP_xlen>> io_csr_in_value_3;
  sc_signal<sc_bv<KP_xlen>> io_csr_in_value_4;
  sc_signal<sc_bv<KP_xlen>> io_csr_in_value_5;
  sc_signal<sc_bv<KP_xlen>> io_csr_in_value_6;
  sc_signal<sc_bv<KP_xlen>> io_csr_in_value_7;
  sc_signal<sc_bv<KP_xlen>> io_csr_in_value_8;
  sc_signal<sc_bv<KP_xlen>> io_csr_in_value_9;
  sc_signal<sc_bv<KP_xlen>> io_csr_in_value_10;
  sc_signal<sc_bv<KP_xlen>> io_csr_in_value_11;
  sc_signal<sc_bv<KP_xlen>> io_csr_in_value_12;
  sc_signal<sc_bv<KP_xlen>> io_csr_out_value_0;
  sc_signal<sc_bv<KP_xlen>> io_csr_out_value_1;
  sc_signal<sc_bv<KP_xlen>> io_csr_out_value_2;
  sc_signal<sc_bv<KP_xlen>> io_csr_out_value_3;
  sc_signal<sc_bv<KP_xlen>> io_csr_out_value_4;
  sc_signal<sc_bv<KP_xlen>> io_csr_out_value_5;
  sc_signal<sc_bv<KP_xlen>> io_csr_out_value_6;
  sc_signal<sc_bv<KP_xlen>> io_csr_out_value_7;
  sc_signal<sc_bv<KP_xlen>> io_csr_out_value_8;
  sc_signal<sc_bv<KP_programCounterBits>> io_ibus_addr;
  sc_signal<sc_bv<KP_fetchDataBits>> io_ibus_rdata;
  sc_signal<sc_bv<KP_programCounterBits>> io_ibus_fault_bits_epc;
  sc_signal<sc_bv<KP_programCounterBits>> io_ibus_fault_bits_addr;
  sc_signal<sc_bv<KP_lsuAddrBits>> io_dbus_addr;
  sc_signal<sc_bv<KP_lsuAddrBits>> io_dbus_adrx;
  sc_signal<sc_bv<32>> io_dbus_pc;
  sc_signal<sc_bv<KP_dbusSize>> io_dbus_size;
  sc_signal<sc_bv<KP_lsuDataBits>> io_dbus_wdata;
  sc_signal<sc_bv<KP_lsuDataBits / 8>> io_dbus_wmask;
  sc_signal<sc_bv<KP_lsuDataBits>> io_dbus_rdata;
  sc_signal<sc_bv<KP_lsuAddrBits>> io_ebus_dbus_addr;
  sc_signal<sc_bv<KP_lsuAddrBits>> io_ebus_dbus_adrx;
  sc_signal<sc_bv<32>> io_ebus_dbus_pc;
  sc_signal<sc_bv<KP_programCounterBits>> io_ebus_fault_bits_epc;
  sc_signal<sc_bv<KP_programCounterBits>> io_ebus_fault_bits_addr;
  sc_signal<sc_bv<KP_dbusSize>> io_ebus_dbus_size;
  sc_signal<sc_bv<KP_lsuDataBits>> io_ebus_dbus_wdata;
  sc_signal<sc_bv<KP_lsuDataBits / 8>> io_ebus_dbus_wmask;
  sc_signal<sc_bv<KP_lsuDataBits>> io_ebus_dbus_rdata;
  sc_signal<bool> io_ebus_internal;
#if KP_exposeDebugPorts
  sc_signal<sc_bv<4>> io_debug_en;
  sc_signal<sc_bv<KP_xlen>> io_debug_cycles;
  sc_signal<bool> io_debug_dbus_valid;
  sc_signal<sc_bv<KP_lsuAddrBits>> io_debug_dbus_bits_addr;
  sc_signal<sc_bv<KP_lsuDataBits>> io_debug_dbus_bits_wdata;
  sc_signal<bool> io_debug_dbus_bits_write;
  sc_signal<bool> io_debug_dispatch_0_instFire;
  sc_signal<bool> io_debug_dispatch_1_instFire;
  sc_signal<bool> io_debug_dispatch_2_instFire;
  sc_signal<bool> io_debug_dispatch_3_instFire;
  sc_signal<sc_bv<KP_programCounterBits>> io_debug_dispatch_0_instAddr;
  sc_signal<sc_bv<KP_programCounterBits>> io_debug_dispatch_1_instAddr;
  sc_signal<sc_bv<KP_programCounterBits>> io_debug_dispatch_2_instAddr;
  sc_signal<sc_bv<KP_programCounterBits>> io_debug_dispatch_3_instAddr;
  sc_signal<sc_bv<32>> io_debug_dispatch_0_instInst;
  sc_signal<sc_bv<32>> io_debug_dispatch_1_instInst;
  sc_signal<sc_bv<32>> io_debug_dispatch_2_instInst;
  sc_signal<sc_bv<32>> io_debug_dispatch_3_instInst;
  sc_signal<bool> io_debug_regfile_writeAddr_0_valid;
  sc_signal<bool> io_debug_regfile_writeAddr_1_valid;
  sc_signal<bool> io_debug_regfile_writeAddr_2_valid;
  sc_signal<bool> io_debug_regfile_writeAddr_3_valid;
  sc_signal<sc_bv<KP_scalarRegCountWidth>> io_debug_regfile_writeAddr_0_bits;
  sc_signal<sc_bv<KP_scalarRegCountWidth>> io_debug_regfile_writeAddr_1_bits;
  sc_signal<sc_bv<KP_scalarRegCountWidth>> io_debug_regfile_writeAddr_2_bits;
  sc_signal<sc_bv<KP_scalarRegCountWidth>> io_debug_regfile_writeAddr_3_bits;
  sc_signal<bool> io_debug_regfile_writeData_0_valid;
  sc_signal<bool> io_debug_regfile_writeData_1_valid;
  sc_signal<bool> io_debug_regfile_writeData_2_valid;
  sc_signal<bool> io_debug_regfile_writeData_3_valid;
  sc_signal<bool> io_debug_regfile_writeData_4_valid;
  sc_signal<bool> io_debug_regfile_writeData_5_valid;
  sc_signal<sc_bv<KP_scalarRegCountWidth>> io_debug_regfile_writeData_0_bits_addr;
  sc_signal<sc_bv<KP_scalarRegCountWidth>> io_debug_regfile_writeData_1_bits_addr;
  sc_signal<sc_bv<KP_scalarRegCountWidth>> io_debug_regfile_writeData_2_bits_addr;
  sc_signal<sc_bv<KP_scalarRegCountWidth>> io_debug_regfile_writeData_3_bits_addr;
  sc_signal<sc_bv<KP_scalarRegCountWidth>> io_debug_regfile_writeData_4_bits_addr;
  sc_signal<sc_bv<KP_scalarRegCountWidth>> io_debug_regfile_writeData_5_bits_addr;
  sc_signal<sc_bv<KP_xlen>> io_debug_regfile_writeData_0_bits_data;
  sc_signal<sc_bv<KP_xlen>> io_debug_regfile_writeData_1_bits_data;
  sc_signal<sc_bv<KP_xlen>> io_debug_regfile_writeData_2_bits_data;
  sc_signal<sc_bv<KP_xlen>> io_debug_regfile_writeData_3_bits_data;
  sc_signal<sc_bv<KP_xlen>> io_debug_regfile_writeData_4_bits_data;
  sc_signal<sc_bv<KP_xlen>> io_debug_regfile_writeData_5_bits_data;

#define IO_DEBUG(x)                                         \
  sc_signal<sc_bv<KP_programCounterBits>> io_debug_addr##x; \
  sc_signal<sc_bv<32>> io_debug_inst##x;
  REPEAT(IO_DEBUG, KP_instructionLanes);
#undef IO_DEBUG
#endif

  io_iflush_ready = 1;
  io_dflush_ready = 1;

  tb.io_halted(io_halted);
  tb.io_fault(io_fault);
  tb.io_ebus_dbus_valid(io_ebus_dbus_valid);
  tb.io_ebus_dbus_ready(io_ebus_dbus_ready);
  tb.io_ebus_fault_valid(io_ebus_fault_valid);
  tb.io_ebus_fault_bits_addr(io_ebus_fault_bits_addr);
  tb.io_ebus_dbus_addr(io_ebus_dbus_addr);

  core.clock(tb.clock);
  core.reset(tb.reset);
  core.io_halted(io_halted);
  core.io_fault(io_fault);
  core.io_wfi(io_wfi);
  core.io_irq(io_irq);
  core.io_debug_req(io_debug_req);
  core.io_ibus_valid(io_ibus_valid);
  core.io_ibus_ready(io_ibus_ready);
  core.io_ibus_fault_valid(io_ibus_fault_valid);
  core.io_ibus_fault_bits_write(io_ibus_fault_bits_write);
  core.io_ibus_fault_bits_addr(io_ibus_fault_bits_addr);
  core.io_ibus_fault_bits_epc(io_ibus_fault_bits_epc);
  core.io_dbus_valid(io_dbus_valid);
  core.io_dbus_ready(io_dbus_ready);
  core.io_dbus_write(io_dbus_write);
  core.io_ebus_dbus_valid(io_ebus_dbus_valid);
  core.io_ebus_dbus_ready(io_ebus_dbus_ready);
  core.io_ebus_dbus_write(io_ebus_dbus_write);
  core.io_ebus_fault_valid(io_ebus_fault_valid);
  core.io_ebus_fault_bits_write(io_ebus_fault_bits_write);
  core.io_ebus_fault_bits_addr(io_ebus_fault_bits_addr);
  core.io_ebus_fault_bits_epc(io_ebus_fault_bits_epc);
  core.io_iflush_valid(io_iflush_valid);
  core.io_iflush_pcNext(io_iflush_pcNext);
  core.io_iflush_ready(io_iflush_ready);
  core.io_dflush_valid(io_dflush_valid);
  core.io_dflush_ready(io_dflush_ready);
  core.io_dflush_all(io_dflush_all);
  core.io_dflush_clean(io_dflush_clean);
  core.io_csr_in_value_0(io_csr_in_value_0);
  core.io_csr_in_value_1(io_csr_in_value_1);
  core.io_csr_in_value_2(io_csr_in_value_2);
  core.io_csr_in_value_3(io_csr_in_value_3);
  core.io_csr_in_value_4(io_csr_in_value_4);
  core.io_csr_in_value_5(io_csr_in_value_5);
  core.io_csr_in_value_6(io_csr_in_value_6);
  core.io_csr_in_value_7(io_csr_in_value_7);
  core.io_csr_in_value_8(io_csr_in_value_8);
  core.io_csr_in_value_9(io_csr_in_value_9);
  core.io_csr_in_value_10(io_csr_in_value_10);
  core.io_csr_in_value_11(io_csr_in_value_11);
  core.io_csr_in_value_12(io_csr_in_value_12);
  core.io_csr_out_value_0(io_csr_out_value_0);
  core.io_csr_out_value_1(io_csr_out_value_1);
  core.io_csr_out_value_2(io_csr_out_value_2);
  core.io_csr_out_value_3(io_csr_out_value_3);
  core.io_csr_out_value_4(io_csr_out_value_4);
  core.io_csr_out_value_5(io_csr_out_value_5);
  core.io_csr_out_value_6(io_csr_out_value_6);
  core.io_csr_out_value_7(io_csr_out_value_7);
  core.io_csr_out_value_8(io_csr_out_value_8);
  core.io_ibus_addr(io_ibus_addr);
  core.io_ibus_rdata(io_ibus_rdata);
  core.io_dbus_addr(io_dbus_addr);
  core.io_dbus_adrx(io_dbus_adrx);
  core.io_dbus_pc(io_dbus_pc);
  core.io_dbus_size(io_dbus_size);
  core.io_dbus_wdata(io_dbus_wdata);
  core.io_dbus_wmask(io_dbus_wmask);
  core.io_dbus_rdata(io_dbus_rdata);
  core.io_ebus_dbus_addr(io_ebus_dbus_addr);
  core.io_ebus_dbus_adrx(io_ebus_dbus_adrx);
  core.io_ebus_dbus_pc(io_ebus_dbus_pc);
  core.io_ebus_dbus_size(io_ebus_dbus_size);
  core.io_ebus_dbus_wdata(io_ebus_dbus_wdata);
  core.io_ebus_dbus_wmask(io_ebus_dbus_wmask);
  core.io_ebus_dbus_rdata(io_ebus_dbus_rdata);
  core.io_ebus_internal(io_ebus_internal);
#if KP_exposeDebugPorts
  core.io_debug_en(io_debug_en);
  core.io_debug_cycles(io_debug_cycles);
  core.io_debug_dbus_valid(io_debug_dbus_valid);
  core.io_debug_dbus_bits_addr(io_debug_dbus_bits_addr);
  core.io_debug_dbus_bits_wdata(io_debug_dbus_bits_wdata);
  core.io_debug_dbus_bits_write(io_debug_dbus_bits_write);
  core.io_debug_dispatch_0_instFire(io_debug_dispatch_0_instFire);
  core.io_debug_dispatch_1_instFire(io_debug_dispatch_1_instFire);
  core.io_debug_dispatch_2_instFire(io_debug_dispatch_2_instFire);
  core.io_debug_dispatch_3_instFire(io_debug_dispatch_3_instFire);
  core.io_debug_dispatch_0_instAddr(io_debug_dispatch_0_instAddr);
  core.io_debug_dispatch_1_instAddr(io_debug_dispatch_1_instAddr);
  core.io_debug_dispatch_2_instAddr(io_debug_dispatch_2_instAddr);
  core.io_debug_dispatch_3_instAddr(io_debug_dispatch_3_instAddr);
  core.io_debug_dispatch_0_instInst(io_debug_dispatch_0_instInst);
  core.io_debug_dispatch_1_instInst(io_debug_dispatch_1_instInst);
  core.io_debug_dispatch_2_instInst(io_debug_dispatch_2_instInst);
  core.io_debug_dispatch_3_instInst(io_debug_dispatch_3_instInst);
  core.io_debug_regfile_writeAddr_0_valid(io_debug_regfile_writeAddr_0_valid);
  core.io_debug_regfile_writeAddr_1_valid(io_debug_regfile_writeAddr_1_valid);
  core.io_debug_regfile_writeAddr_2_valid(io_debug_regfile_writeAddr_2_valid);
  core.io_debug_regfile_writeAddr_3_valid(io_debug_regfile_writeAddr_3_valid);
  core.io_debug_regfile_writeAddr_0_bits(io_debug_regfile_writeAddr_0_bits);
  core.io_debug_regfile_writeAddr_1_bits(io_debug_regfile_writeAddr_1_bits);
  core.io_debug_regfile_writeAddr_2_bits(io_debug_regfile_writeAddr_2_bits);
  core.io_debug_regfile_writeAddr_3_bits(io_debug_regfile_writeAddr_3_bits);
  core.io_debug_regfile_writeData_0_valid(io_debug_regfile_writeData_0_valid);
  core.io_debug_regfile_writeData_1_valid(io_debug_regfile_writeData_1_valid);
  core.io_debug_regfile_writeData_2_valid(io_debug_regfile_writeData_2_valid);
  core.io_debug_regfile_writeData_3_valid(io_debug_regfile_writeData_3_valid);
  core.io_debug_regfile_writeData_4_valid(io_debug_regfile_writeData_4_valid);
  core.io_debug_regfile_writeData_5_valid(io_debug_regfile_writeData_5_valid);
  core.io_debug_regfile_writeData_0_bits_addr(io_debug_regfile_writeData_0_bits_addr);
  core.io_debug_regfile_writeData_1_bits_addr(io_debug_regfile_writeData_1_bits_addr);
  core.io_debug_regfile_writeData_2_bits_addr(io_debug_regfile_writeData_2_bits_addr);
  core.io_debug_regfile_writeData_3_bits_addr(io_debug_regfile_writeData_3_bits_addr);
  core.io_debug_regfile_writeData_4_bits_addr(io_debug_regfile_writeData_4_bits_addr);
  core.io_debug_regfile_writeData_5_bits_addr(io_debug_regfile_writeData_5_bits_addr);
  core.io_debug_regfile_writeData_0_bits_data(io_debug_regfile_writeData_0_bits_data);
  core.io_debug_regfile_writeData_1_bits_data(io_debug_regfile_writeData_1_bits_data);
  core.io_debug_regfile_writeData_2_bits_data(io_debug_regfile_writeData_2_bits_data);
  core.io_debug_regfile_writeData_3_bits_data(io_debug_regfile_writeData_3_bits_data);
  core.io_debug_regfile_writeData_4_bits_data(io_debug_regfile_writeData_4_bits_data);
  core.io_debug_regfile_writeData_5_bits_data(io_debug_regfile_writeData_5_bits_data);

#define BIND_DEBUG(x)                       \
  core.io_debug_addr_##x(io_debug_addr##x); \
  core.io_debug_inst_##x(io_debug_inst##x);
  REPEAT(BIND_DEBUG, KP_instructionLanes);
#undef BIND_DEBUG
#endif

  mif.clock(tb.clock);
  mif.reset(tb.reset);
  mif.io_ibus_valid(io_ibus_valid);
  mif.io_ibus_ready(io_ibus_ready);
  mif.io_ibus_addr(io_ibus_addr);
  mif.io_ibus_rdata(io_ibus_rdata);
  mif.io_dbus_valid(io_dbus_valid);
  mif.io_dbus_ready(io_dbus_ready);
  mif.io_dbus_write(io_dbus_write);
  mif.io_dbus_addr(io_dbus_addr);
  mif.io_dbus_adrx(io_dbus_adrx);
  mif.io_dbus_size(io_dbus_size);
  mif.io_dbus_wdata(io_dbus_wdata);
  mif.io_dbus_wmask(io_dbus_wmask);
  mif.io_dbus_rdata(io_dbus_rdata);
  mif.io_ibus_fault_valid(io_ibus_fault_valid);
  mif.io_ibus_fault_bits_write(io_ibus_fault_bits_write);
  mif.io_ibus_fault_bits_addr(io_ibus_fault_bits_addr);
  mif.io_ibus_fault_bits_epc(io_ibus_fault_bits_epc);

  dbg.clock(tb.clock);
  dbg.reset(tb.reset);

  if (trace) {
    tb.trace(&core);
  }

  tb.start();
}

int sc_main(int argc, char *argv[]) {
  absl::SetProgramUsageMessage("CoralNPU SystemC simulation tool");
  auto out_args = absl::ParseCommandLine(argc, argv);
  argc          = out_args.size();
  argv          = &out_args[0];
  if (argc != 2) {
    fprintf(stderr, "Need one binary input file\n");
    return 1;
  }
  const char *path = argv[1];

  Core_run(Sysc_tb::get_name(argv[0]), path, absl::GetFlag(FLAGS_cycles),
           absl::GetFlag(FLAGS_trace));
  return 0;
}
