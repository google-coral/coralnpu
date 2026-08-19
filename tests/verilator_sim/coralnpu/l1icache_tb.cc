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

#include "tests/verilator_sim/sysc_tb.h"

#include "VL1ICache.h"

#include "tests/verilator_sim/coralnpu/coralnpu_cfg.h"

template <typename T>
struct get_port_width;

template <typename T>
struct get_port_width<T&> : get_port_width<T> {};

template <int W>
struct get_port_width<sc_core::sc_in<sc_dt::sc_bv<W>>> {
  static const int value = W;
};

template <int W>
struct get_port_width<sc_core::sc_out<sc_dt::sc_bv<W>>> {
  static const int value = W;
};

struct L1ICache_tb : Sysc_tb {
  static const int PC_WIDTH = get_port_width<decltype(VL1ICache::io_flush_pcNext)>::value;
  static const int ADDR_WIDTH = get_port_width<decltype(VL1ICache::io_ibus_addr)>::value;
  static const int FAULT_ADDR_WIDTH = get_port_width<decltype(VL1ICache::io_ibus_fault_bits_addr)>::value;
  static const int FAULT_EPC_WIDTH = get_port_width<decltype(VL1ICache::io_ibus_fault_bits_epc)>::value;

  sc_out<bool> io_flush_valid;
  sc_out<sc_bv<PC_WIDTH> > io_flush_pcNext;
  sc_in<bool> io_flush_ready;
  sc_out<bool> io_ibus_valid;
  sc_in<bool> io_ibus_ready;
  sc_out<sc_bv<ADDR_WIDTH> > io_ibus_addr;
  sc_in<sc_bv<kL1IAxiBits> > io_ibus_rdata;
  sc_in<bool> io_ibus_fault_valid;
  sc_in<bool> io_ibus_fault_bits_write;
  sc_in<sc_bv<FAULT_ADDR_WIDTH>> io_ibus_fault_bits_addr;
  sc_in<sc_bv<FAULT_EPC_WIDTH>> io_ibus_fault_bits_epc;
  sc_in<bool> io_axi_read_addr_valid;
  sc_out<bool> io_axi_read_addr_ready;
  sc_in<sc_bv<kL1IAxiId> > io_axi_read_addr_bits_id;
  sc_in<sc_bv<32> > io_axi_read_addr_bits_addr;
  sc_in<sc_bv<4> > io_axi_read_addr_bits_region;
  sc_in<sc_bv<4> > io_axi_read_addr_bits_qos;
  sc_in<sc_bv<3> > io_axi_read_addr_bits_prot;
  sc_in<sc_bv<4> > io_axi_read_addr_bits_cache;
  sc_in<bool> io_axi_read_addr_bits_lock;
  sc_in<sc_bv<2> > io_axi_read_addr_bits_burst;
  sc_in<sc_bv<3> > io_axi_read_addr_bits_size;
  sc_in<sc_bv<8> > io_axi_read_addr_bits_len;
  sc_out<bool> io_axi_read_data_valid;
  sc_in<bool> io_axi_read_data_ready;
  sc_out<sc_bv<2> > io_axi_read_data_bits_resp;
  sc_out<sc_bv<kL1IAxiId> > io_axi_read_data_bits_id;
  sc_out<sc_bv<kL1IAxiBits> > io_axi_read_data_bits_data;
  sc_out<bool> io_axi_read_data_bits_last;
  sc_in<bool> io_volt_sel;

  using Sysc_tb::Sysc_tb;

  void posedge() {
    // flush
    io_flush_valid = rand_int(0, 255) == 0;

    // ibus
    if (ibus_resp_pipeline_) {
      ibus_resp_pipeline_ = false;
      for (int i = 0; i < ibusw_; ++i) {
        uint32_t ref = ibus_resp_data_ + i * 4;
        uint32_t dut = io_ibus_rdata.read().get_word(i);
        check(ref == dut, "ibus read data");
      }
    }

    if (io_ibus_valid && io_ibus_ready) {
      ibus_resp_pipeline_ = true;
      ibus_resp_data_ = io_ibus_addr.read().get_word(0) & ~(ibusb_ - 1);

      command_t cmd({io_ibus_addr.read().get_word(0)});
      history_.write(cmd);
      if (history_.count() > 16) {
        history_.remove();
      }
    }

    if (!io_ibus_valid || io_ibus_ready) {  // latch transaction
      command_t cmd;
      bool newaddr = rand_int(0, 3) == 0 || !history_.rand(cmd);
      uint32_t addr = newaddr ? rand_uint32() : cmd.addr;
      if (rand_int(0, 7) == 0) {
        addr &= 0x3fff;
      }
      io_ibus_valid = rand_bool();
      io_ibus_addr = addr;
    }

    timeout_ = io_ibus_ready ? 0 : timeout_ + io_ibus_valid;
    check(timeout_ < 100, "ibus timeout");

    // kxi_read_addr
    io_axi_read_addr_ready = rand_bool();

    if (io_axi_read_addr_valid && io_axi_read_addr_ready) {
      uint32_t id = io_axi_read_addr_bits_id.read().get_word(0);
      uint32_t addr = io_axi_read_addr_bits_addr.read().get_word(0);
      response_t resp({id, addr});
      resp_.write(resp);
    }

    // kxi_read_data
    io_axi_read_data_valid = false;
    io_axi_read_data_bits_id = 0;
    io_axi_read_data_bits_data = 0;

    if (io_axi_read_data_valid && io_axi_read_data_ready) {
      check(resp_.remove(), "no response to erase");
      resp_.shuffle();
    }

    response_t resp;
    if (resp_.next(resp)) {
      io_axi_read_data_valid = rand_bool();
      io_axi_read_data_bits_id = resp.id;
      uint32_t data = resp.data;
      sc_bv<kL1IAxiBits> out;
      for (int i = 0; i < axiw_; ++i) {
        out.set_word(i, data);
        data += 4;
      }
      io_axi_read_data_bits_data = out;
    }
  }

 private:
  struct command_t {
    uint32_t addr;
  };

  struct response_t {
    uint32_t id;
    uint32_t data;
  };

  const int ibusb_ = kL1IAxiBits / 8;
  const int ibusw_ = kL1IAxiBits / 32;
  [[maybe_unused]] const int axib_ = kL1IAxiBits / 8;
  const int axiw_ = kL1IAxiBits / 32;

  int timeout_ = 0;

  bool ibus_resp_pipeline_ = false;
  uint32_t ibus_resp_data_ = 0;
  fifo_t<command_t> history_;
  fifo_t<response_t> resp_;
};

static void L1ICache_test(char* name, int loops, bool trace) {
  sc_signal<bool> io_flush_valid;
  sc_signal<sc_bv<L1ICache_tb::PC_WIDTH> > io_flush_pcNext;
  sc_signal<bool> io_flush_ready;
  sc_signal<bool> io_ibus_valid;
  sc_signal<bool> io_ibus_ready;
  sc_signal<sc_bv<L1ICache_tb::ADDR_WIDTH> > io_ibus_addr;
  sc_signal<sc_bv<kL1IAxiBits> > io_ibus_rdata;
  sc_signal<bool> io_ibus_fault_valid;
  sc_signal<bool> io_ibus_fault_bits_write;
  sc_signal<sc_bv<L1ICache_tb::FAULT_ADDR_WIDTH>> io_ibus_fault_bits_addr;
  sc_signal<sc_bv<L1ICache_tb::FAULT_EPC_WIDTH>> io_ibus_fault_bits_epc;
  sc_signal<bool> io_axi_read_addr_valid;
  sc_signal<bool> io_axi_read_addr_ready;
  sc_signal<sc_bv<kL1IAxiId> > io_axi_read_addr_bits_id;
  sc_signal<sc_bv<32> > io_axi_read_addr_bits_addr;
  sc_signal<sc_bv<4> > io_axi_read_addr_bits_region;
  sc_signal<sc_bv<4> > io_axi_read_addr_bits_qos;
  sc_signal<sc_bv<3> > io_axi_read_addr_bits_prot;
  sc_signal<sc_bv<4> > io_axi_read_addr_bits_cache;
  sc_signal<bool> io_axi_read_addr_bits_lock;
  sc_signal<sc_bv<2> > io_axi_read_addr_bits_burst;
  sc_signal<sc_bv<3> > io_axi_read_addr_bits_size;
  sc_signal<sc_bv<8> > io_axi_read_addr_bits_len;
  sc_signal<bool> io_axi_read_data_valid;
  sc_signal<bool> io_axi_read_data_ready;
  sc_signal<sc_bv<2> > io_axi_read_data_bits_resp;
  sc_signal<sc_bv<kL1IAxiId> > io_axi_read_data_bits_id;
  sc_signal<sc_bv<kL1IAxiBits> > io_axi_read_data_bits_data;
  sc_signal<bool> io_axi_read_data_bits_last;
  sc_signal<bool> io_volt_sel;

  L1ICache_tb tb("L1ICache_tb", loops, true /*random*/);
  VL1ICache l1icache(name);

  if (trace) {
    tb.trace(&l1icache);
  }

  l1icache.clock(tb.clock);
  l1icache.reset(tb.reset);
  BIND2(tb, l1icache, io_flush_valid);
  BIND2(tb, l1icache, io_flush_pcNext);
  BIND2(tb, l1icache, io_flush_ready);
  BIND2(tb, l1icache, io_ibus_valid);
  BIND2(tb, l1icache, io_ibus_ready);
  BIND2(tb, l1icache, io_ibus_addr);
  BIND2(tb, l1icache, io_ibus_rdata);
  BIND2(tb, l1icache, io_ibus_fault_valid);
  BIND2(tb, l1icache, io_ibus_fault_bits_write);
  BIND2(tb, l1icache, io_ibus_fault_bits_addr);
  BIND2(tb, l1icache, io_ibus_fault_bits_epc);
  BIND2(tb, l1icache, io_axi_read_addr_valid);
  BIND2(tb, l1icache, io_axi_read_addr_ready);
  BIND2(tb, l1icache, io_axi_read_addr_bits_id);
  BIND2(tb, l1icache, io_axi_read_addr_bits_addr);
  BIND2(tb, l1icache, io_axi_read_addr_bits_region);
  BIND2(tb, l1icache, io_axi_read_addr_bits_qos);
  BIND2(tb, l1icache, io_axi_read_addr_bits_prot);
  BIND2(tb, l1icache, io_axi_read_addr_bits_cache);
  BIND2(tb, l1icache, io_axi_read_addr_bits_lock);
  BIND2(tb, l1icache, io_axi_read_addr_bits_burst);
  BIND2(tb, l1icache, io_axi_read_addr_bits_size);
  BIND2(tb, l1icache, io_axi_read_addr_bits_len);
  BIND2(tb, l1icache, io_axi_read_data_ready);
  BIND2(tb, l1icache, io_axi_read_data_valid);
  BIND2(tb, l1icache, io_axi_read_data_bits_data);
  BIND2(tb, l1icache, io_axi_read_data_bits_id);
  BIND2(tb, l1icache, io_axi_read_data_bits_resp);
  BIND2(tb, l1icache, io_axi_read_data_bits_last);
  BIND2(tb, l1icache, io_volt_sel);

  tb.start();
}

int sc_main(int argc, char *argv[]) {
  L1ICache_test(Sysc_tb::get_name(argv[0]), 1000000, false);
  return 0;
}
