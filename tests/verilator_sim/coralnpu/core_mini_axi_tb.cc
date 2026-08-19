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

#include "tests/verilator_sim/coralnpu/core_mini_axi_tb.h"

#include <elf.h>
#include <fcntl.h>
#include <sys/mman.h>
#include <sys/stat.h>

#include <cstddef>
#include <memory>
#include <string>

#include "absl/log/check.h"
#include "absl/log/log.h"
#include "absl/status/status.h"
#include "tests/verilator_sim/elf.h"
#include "tests/verilator_sim/sysc_tb.h"

/* clang-format off */
#include <systemc>
#include "traffic-generators/traffic-desc.h"
namespace internal {
#include "tests/test-modules/utils.h"
}
using namespace internal;
/* clang-format on */

const char* CoreMiniAxi_tb::kCoreMiniAxiModelName = STRINGIFY(VERILATOR_MODEL);

CoreMiniAxi_tb::CoreMiniAxi_tb(sc_module_name n, int loops, bool random,
                               bool debug_axi, bool instr_trace,
                               bool backdoor_load,
                               std::optional<std::function<void()>> wfi_cb,
                               std::optional<std::function<void()>> halted_cb)
    : Sysc_tb(n, loops, random),
      tg_("traffic_generator"),
      tlm2axi_bridge_("tlm2axi_bridge"),
      tlm_mux_("tlm_mux"),
      tohost_initiator_socket_("tohost_initiator_socket"),
      axi2tlm_bridge_("axi2tlm_bridge"),
      tlm2axi_checker_("tlm2axi_checker"),
      tlm2axi_signals_("tlm2axi_signals"),
      axi2tlm_signals_("axi2tlm_signals"),
      xbar_("xbar"),
      wfi_cb_(wfi_cb),
      halted_cb_(halted_cb),
      instr_trace_(instr_trace),
      backdoor_load_(backdoor_load) {
  if (CoreMiniAxi_tb::singleton_ != nullptr) {
    CHECK(false);
  }
  CoreMiniAxi_tb::singleton_ = this;
  core_ = std::make_unique<VERILATOR_MODEL>("core");

  // Initialize fd_map_.
  fd_map_.emplace(0, 0);
  fd_map_.emplace(1, 1);
  fd_map_.emplace(2, 2);
  fd_map_.emplace(-100, AT_FDCWD);

  // TLM2AXI
  tlm2axi_bridge_.clk(clock);
  tlm2axi_bridge_.resetn(resetn);
  // AXI Protocol checker
  tlm2axi_checker_.clk(clock);
  tlm2axi_checker_.resetn(resetn);

  // AXI2TLM
  axi2tlm_bridge_.clk(clock);
  axi2tlm_bridge_.resetn(resetn);

  tlm2axi_signals_.connect(tlm2axi_bridge_);
  tlm2axi_signals_.connect(tlm2axi_checker_);
  axi2tlm_signals_.connect(axi2tlm_bridge_);

  Connect();

  SC_HAS_PROCESS(CoreMiniAxi_tb);
  SC_THREAD(tohost_reader_thread);

  tg_.setStartDelay(sc_time(5, SC_NS));
  if (debug_axi) {
    tg_.enableDebug();
  }

  axi2tlm_bridge_.socket.bind(xbar_.socket());
}

CoreMiniAxi_tb::~CoreMiniAxi_tb() { singleton_ = nullptr; }

void CoreMiniAxi_tb::Connect() {
  // TLM sockets
  tg_.socket.bind(*tlm_mux_.t_sk[0]);
  tohost_initiator_socket_.bind(*tlm_mux_.t_sk[1]);
  tlm_mux_.memmap(0, 0xffffffffffffffffull, ADDRMODE_RELATIVE, -1, tlm2axi_bridge_.tgt_socket);

  core_->io_aclk(clock);
  core_->io_aresetn(resetn);
  core_->io_halted(io_halted);
  core_->io_fault(io_fault);
  core_->io_wfi(io_wfi);
  core_->io_irq(io_irq);
  core_->io_timer_irq(io_timer_irq);
  core_->io_software_irq(io_software_irq);
  core_->io_te(io_te);
  core_->io_boot_addr(io_boot_addr);

#if KP_exposeDebugPorts
  core_->io_debug_en(debug_io_.en);
  core_->io_debug_cycles(debug_io_.cycles);
  core_->io_debug_addr_0(debug_io_.addr_0);
  core_->io_debug_addr_1(debug_io_.addr_1);
  core_->io_debug_addr_2(debug_io_.addr_2);
  core_->io_debug_addr_3(debug_io_.addr_3);
  core_->io_debug_inst_0(debug_io_.inst_0);
  core_->io_debug_inst_1(debug_io_.inst_1);
  core_->io_debug_inst_2(debug_io_.inst_2);
  core_->io_debug_inst_3(debug_io_.inst_3);
  core_->io_debug_dbus_valid(debug_io_.dbus_valid);
  core_->io_debug_dbus_bits_addr(debug_io_.dbus_bits_addr);
  core_->io_debug_dbus_bits_wdata(debug_io_.dbus_bits_wdata);
  core_->io_debug_dbus_bits_write(debug_io_.dbus_bits_write);
  core_->io_debug_dispatch_0_instFire(debug_io_.dispatch_0_instFire);
  core_->io_debug_dispatch_1_instFire(debug_io_.dispatch_1_instFire);
  core_->io_debug_dispatch_2_instFire(debug_io_.dispatch_2_instFire);
  core_->io_debug_dispatch_3_instFire(debug_io_.dispatch_3_instFire);
  core_->io_debug_dispatch_0_instAddr(debug_io_.dispatch_0_instAddr);
  core_->io_debug_dispatch_1_instAddr(debug_io_.dispatch_1_instAddr);
  core_->io_debug_dispatch_2_instAddr(debug_io_.dispatch_2_instAddr);
  core_->io_debug_dispatch_3_instAddr(debug_io_.dispatch_3_instAddr);
  core_->io_debug_dispatch_0_instInst(debug_io_.dispatch_0_instInst);
  core_->io_debug_dispatch_1_instInst(debug_io_.dispatch_1_instInst);
  core_->io_debug_dispatch_2_instInst(debug_io_.dispatch_2_instInst);
  core_->io_debug_dispatch_3_instInst(debug_io_.dispatch_3_instInst);
  core_->io_debug_regfile_writeAddr_0_valid(debug_io_.regfile_writeAddr_0_valid);
  core_->io_debug_regfile_writeAddr_1_valid(debug_io_.regfile_writeAddr_1_valid);
  core_->io_debug_regfile_writeAddr_2_valid(debug_io_.regfile_writeAddr_2_valid);
  core_->io_debug_regfile_writeAddr_3_valid(debug_io_.regfile_writeAddr_3_valid);
  core_->io_debug_regfile_writeAddr_0_bits(debug_io_.regfile_writeAddr_0_bits);
  core_->io_debug_regfile_writeAddr_1_bits(debug_io_.regfile_writeAddr_1_bits);
  core_->io_debug_regfile_writeAddr_2_bits(debug_io_.regfile_writeAddr_2_bits);
  core_->io_debug_regfile_writeAddr_3_bits(debug_io_.regfile_writeAddr_3_bits);
  core_->io_debug_regfile_writeData_0_valid(debug_io_.regfile_writeData_0_valid);
  core_->io_debug_regfile_writeData_1_valid(debug_io_.regfile_writeData_1_valid);
  core_->io_debug_regfile_writeData_2_valid(debug_io_.regfile_writeData_2_valid);
  core_->io_debug_regfile_writeData_3_valid(debug_io_.regfile_writeData_3_valid);
  core_->io_debug_regfile_writeData_4_valid(debug_io_.regfile_writeData_4_valid);
  core_->io_debug_regfile_writeData_5_valid(debug_io_.regfile_writeData_5_valid);
  core_->io_debug_regfile_writeData_0_bits_addr(debug_io_.regfile_writeData_0_bits_addr);
  core_->io_debug_regfile_writeData_1_bits_addr(debug_io_.regfile_writeData_1_bits_addr);
  core_->io_debug_regfile_writeData_2_bits_addr(debug_io_.regfile_writeData_2_bits_addr);
  core_->io_debug_regfile_writeData_3_bits_addr(debug_io_.regfile_writeData_3_bits_addr);
  core_->io_debug_regfile_writeData_4_bits_addr(debug_io_.regfile_writeData_4_bits_addr);
  core_->io_debug_regfile_writeData_5_bits_addr(debug_io_.regfile_writeData_5_bits_addr);
  core_->io_debug_regfile_writeData_0_bits_data(debug_io_.regfile_writeData_0_bits_data);
  core_->io_debug_regfile_writeData_1_bits_data(debug_io_.regfile_writeData_1_bits_data);
  core_->io_debug_regfile_writeData_2_bits_data(debug_io_.regfile_writeData_2_bits_data);
  core_->io_debug_regfile_writeData_3_bits_data(debug_io_.regfile_writeData_3_bits_data);
  core_->io_debug_regfile_writeData_4_bits_data(debug_io_.regfile_writeData_4_bits_data);
  core_->io_debug_regfile_writeData_5_bits_data(debug_io_.regfile_writeData_5_bits_data);
#if (KP_enableFloat == true)
  core_->io_debug_float_writeAddr_valid(debug_io_.float_writeAddr_valid);
  core_->io_debug_float_writeAddr_bits(debug_io_.float_writeAddr_bits);
  core_->io_debug_float_writeData_0_valid(debug_io_.float_writeData_0_valid);
  core_->io_debug_float_writeData_1_valid(debug_io_.float_writeData_1_valid);
  core_->io_debug_float_writeData_0_bits_addr(debug_io_.float_writeData_0_bits_addr);
  core_->io_debug_float_writeData_1_bits_addr(debug_io_.float_writeData_1_bits_addr);
  core_->io_debug_float_writeData_0_bits_data(debug_io_.float_writeData_0_bits_data);
  core_->io_debug_float_writeData_1_bits_data(debug_io_.float_writeData_1_bits_data);
#endif
#if (KP_enableRvv == true)
#define BIND_RB_DEBUG_IO_VEC(x, y) \
  core_->io_debug_rb_inst_##x##_bits_vecWrites_##y##_valid(debug_io_.rb_inst_##x##_bits_vecWrites_##y##_valid); \
  core_->io_debug_rb_inst_##x##_bits_vecWrites_##y##_bits_data(debug_io_.rb_inst_##x##_bits_vecWrites_##y##_bits_data); \
  core_->io_debug_rb_inst_##x##_bits_vecWrites_##y##_bits_idx(debug_io_.rb_inst_##x##_bits_vecWrites_##y##_bits_idx);
#define BIND_RB_DEBUG_IO_VECS_8(x) \
  BIND_RB_DEBUG_IO_VEC(x, 0) BIND_RB_DEBUG_IO_VEC(x, 1) BIND_RB_DEBUG_IO_VEC(x, 2) BIND_RB_DEBUG_IO_VEC(x, 3) \
  BIND_RB_DEBUG_IO_VEC(x, 4) BIND_RB_DEBUG_IO_VEC(x, 5) BIND_RB_DEBUG_IO_VEC(x, 6) BIND_RB_DEBUG_IO_VEC(x, 7)
#else
#define BIND_RB_DEBUG_IO_VECS_8(x)
#endif
#define BIND_RB_DEBUG_IO(x) \
  core_->io_debug_rb_inst_##x##_valid(debug_io_.rb_inst_##x##_valid); \
  core_->io_debug_rb_inst_##x##_bits_pc(debug_io_.rb_inst_##x##_bits_pc); \
  core_->io_debug_rb_inst_##x##_bits_inst(debug_io_.rb_inst_##x##_bits_inst); \
  core_->io_debug_rb_inst_##x##_bits_idx(debug_io_.rb_inst_##x##_bits_idx); \
  core_->io_debug_rb_inst_##x##_bits_data(debug_io_.rb_inst_##x##_bits_data); \
  core_->io_debug_rb_inst_##x##_bits_trap(debug_io_.rb_inst_##x##_bits_trap); \
  BIND_RB_DEBUG_IO_VECS_8(x)
  REPEAT(BIND_RB_DEBUG_IO, KP_retirementLanes);
#undef BIND_RB_DEBUG_IO
#undef BIND_RB_DEBUG_IO_VECS_8
#undef BIND_RB_DEBUG_IO_VEC
#endif
  core_->io_dm_req_valid(dm_io_.req_valid);
  core_->io_dm_req_ready(dm_io_.req_ready);
  core_->io_dm_req_bits_address(dm_io_.req_bits_address);
  core_->io_dm_req_bits_data(dm_io_.req_bits_data);
  core_->io_dm_req_bits_op(dm_io_.req_bits_op);
  core_->io_dm_rsp_valid(dm_io_.rsp_valid);
  core_->io_dm_rsp_ready(dm_io_.rsp_valid);
  core_->io_dm_rsp_bits_data(dm_io_.rsp_bits_data);
  core_->io_dm_rsp_bits_op(dm_io_.rsp_bits_op);

  // AR
  core_->io_axi_master_read_addr_ready(axi2tlm_signals_.arready);
  core_->io_axi_master_read_addr_valid(axi2tlm_signals_.arvalid);
  core_->io_axi_master_read_addr_bits_addr(axi2tlm_signals_.araddr);
  core_->io_axi_master_read_addr_bits_prot(axi2tlm_signals_.arprot);
  core_->io_axi_master_read_addr_bits_id(axi2tlm_signals_.arid);
  core_->io_axi_master_read_addr_bits_len(axi2tlm_signals_.arlen);
  core_->io_axi_master_read_addr_bits_size(axi2tlm_signals_.arsize);
  core_->io_axi_master_read_addr_bits_burst(axi2tlm_signals_.arburst);
  core_->io_axi_master_read_addr_bits_lock(axi2tlm_signals_.arlock);
  core_->io_axi_master_read_addr_bits_cache(axi2tlm_signals_.arcache);
  core_->io_axi_master_read_addr_bits_qos(axi2tlm_signals_.arqos);
  core_->io_axi_master_read_addr_bits_region(axi2tlm_signals_.arregion);
  // R
  core_->io_axi_master_read_data_ready(axi2tlm_signals_.rready);
  core_->io_axi_master_read_data_valid(axi2tlm_signals_.rvalid);
  core_->io_axi_master_read_data_bits_data(axi2tlm_signals_.rdata);
  core_->io_axi_master_read_data_bits_id(axi2tlm_signals_.rid);
  core_->io_axi_master_read_data_bits_resp(axi2tlm_signals_.rresp);
  core_->io_axi_master_read_data_bits_last(axi2tlm_signals_.rlast);
  // AW
  core_->io_axi_master_write_addr_ready(axi2tlm_signals_.awready);
  core_->io_axi_master_write_addr_valid(axi2tlm_signals_.awvalid);
  core_->io_axi_master_write_addr_bits_addr(axi2tlm_signals_.awaddr);
  core_->io_axi_master_write_addr_bits_prot(axi2tlm_signals_.awprot);
  core_->io_axi_master_write_addr_bits_id(axi2tlm_signals_.awid);
  core_->io_axi_master_write_addr_bits_len(axi2tlm_signals_.awlen);
  core_->io_axi_master_write_addr_bits_size(axi2tlm_signals_.awsize);
  core_->io_axi_master_write_addr_bits_burst(axi2tlm_signals_.awburst);
  core_->io_axi_master_write_addr_bits_lock(axi2tlm_signals_.awlock);
  core_->io_axi_master_write_addr_bits_cache(axi2tlm_signals_.awcache);
  core_->io_axi_master_write_addr_bits_qos(axi2tlm_signals_.awqos);
  core_->io_axi_master_write_addr_bits_region(axi2tlm_signals_.awregion);
  // W
  core_->io_axi_master_write_data_ready(axi2tlm_signals_.wready);
  core_->io_axi_master_write_data_valid(axi2tlm_signals_.wvalid);
  core_->io_axi_master_write_data_bits_data(axi2tlm_signals_.wdata);
  core_->io_axi_master_write_data_bits_last(axi2tlm_signals_.wlast);
  core_->io_axi_master_write_data_bits_strb(axi2tlm_signals_.wstrb);
  // B
  core_->io_axi_master_write_resp_ready(axi2tlm_signals_.bready);
  core_->io_axi_master_write_resp_valid(axi2tlm_signals_.bvalid);
  core_->io_axi_master_write_resp_bits_id(axi2tlm_signals_.bid);
  core_->io_axi_master_write_resp_bits_resp(axi2tlm_signals_.bresp);

  // AR
  core_->io_axi_slave_read_addr_ready(tlm2axi_signals_.arready);
  core_->io_axi_slave_read_addr_valid(tlm2axi_signals_.arvalid);
  core_->io_axi_slave_read_addr_bits_addr(tlm2axi_signals_.araddr);
  core_->io_axi_slave_read_addr_bits_prot(tlm2axi_signals_.arprot);
  core_->io_axi_slave_read_addr_bits_id(tlm2axi_signals_.arid);
  core_->io_axi_slave_read_addr_bits_len(tlm2axi_signals_.arlen);
  core_->io_axi_slave_read_addr_bits_size(tlm2axi_signals_.arsize);
  core_->io_axi_slave_read_addr_bits_burst(tlm2axi_signals_.arburst);
  core_->io_axi_slave_read_addr_bits_lock(tlm2axi_signals_.arlock);
  core_->io_axi_slave_read_addr_bits_cache(tlm2axi_signals_.arcache);
  core_->io_axi_slave_read_addr_bits_qos(tlm2axi_signals_.arqos);
  core_->io_axi_slave_read_addr_bits_region(tlm2axi_signals_.arregion);
  // R
  core_->io_axi_slave_read_data_ready(tlm2axi_signals_.rready);
  core_->io_axi_slave_read_data_valid(tlm2axi_signals_.rvalid);
  core_->io_axi_slave_read_data_bits_data(tlm2axi_signals_.rdata);
  core_->io_axi_slave_read_data_bits_id(tlm2axi_signals_.rid);
  core_->io_axi_slave_read_data_bits_resp(tlm2axi_signals_.rresp);
  core_->io_axi_slave_read_data_bits_last(tlm2axi_signals_.rlast);
  // AW
  core_->io_axi_slave_write_addr_ready(tlm2axi_signals_.awready);
  core_->io_axi_slave_write_addr_valid(tlm2axi_signals_.awvalid);
  core_->io_axi_slave_write_addr_bits_addr(tlm2axi_signals_.awaddr);
  core_->io_axi_slave_write_addr_bits_prot(tlm2axi_signals_.awprot);
  core_->io_axi_slave_write_addr_bits_id(tlm2axi_signals_.awid);
  core_->io_axi_slave_write_addr_bits_len(tlm2axi_signals_.awlen);
  core_->io_axi_slave_write_addr_bits_size(tlm2axi_signals_.awsize);
  core_->io_axi_slave_write_addr_bits_burst(tlm2axi_signals_.awburst);
  core_->io_axi_slave_write_addr_bits_lock(tlm2axi_signals_.awlock);
  core_->io_axi_slave_write_addr_bits_cache(tlm2axi_signals_.awcache);
  core_->io_axi_slave_write_addr_bits_qos(tlm2axi_signals_.awqos);
  core_->io_axi_slave_write_addr_bits_region(tlm2axi_signals_.awregion);
  // W
  core_->io_axi_slave_write_data_ready(tlm2axi_signals_.wready);
  core_->io_axi_slave_write_data_valid(tlm2axi_signals_.wvalid);
  core_->io_axi_slave_write_data_bits_data(tlm2axi_signals_.wdata);
  core_->io_axi_slave_write_data_bits_last(tlm2axi_signals_.wlast);
  core_->io_axi_slave_write_data_bits_strb(tlm2axi_signals_.wstrb);
  // B
  core_->io_axi_slave_write_resp_ready(tlm2axi_signals_.bready);
  core_->io_axi_slave_write_resp_valid(tlm2axi_signals_.bvalid);
  core_->io_axi_slave_write_resp_bits_id(tlm2axi_signals_.bid);
  core_->io_axi_slave_write_resp_bits_resp(tlm2axi_signals_.bresp);
}

absl::Status CoreMiniAxi_tb::LoadElfSync(const std::string& file_name) {
  CHECK_OK(LoadElfAsync(file_name));
  absl::MutexLock lock(transfer_queue_mtx_);
  transfer_queue_cv_.Wait(&transfer_queue_mtx_);
  return absl::OkStatus();
}

absl::Status CoreMiniAxi_tb::LoadElfAsync(const std::string& file_name) {
  absl::MutexLock lock(transfer_queue_mtx_);
  int fd = open(file_name.c_str(), 0);
  CHECK(fd > 0);
  struct stat sb;
  CHECK(fstat(fd, &sb) == 0);
  auto file_size = sb.st_size;
  auto file_data = mmap(nullptr, file_size, PROT_READ, MAP_PRIVATE, fd, 0);
  CHECK(file_data != MAP_FAILED);
  close(fd);

  uint32_t elf_magic = 0x464c457f;
  uint8_t* data8 = reinterpret_cast<uint8_t*>(file_data);
  if (memcmp(file_data, &elf_magic, sizeof(elf_magic)) == 0) {
    std::vector<DataTransfer> elf_transfers;
    const Elf32_Ehdr* elf_header = reinterpret_cast<Elf32_Ehdr*>(file_data);
    auto entry_point = elf_header->e_entry;
    // Reserve space for write+read+expect for each section, and one additional
    // for the entry point CSR.
    elf_transfers.reserve(3 * elf_header->e_phnum + 1);
    ::LoadElf(data8,
              [this, &elf_transfers](void* dest, const void* src, size_t count) {
                uint64_t addr = reinterpret_cast<uint64_t>(dest);
                uint32_t itcm_size = KP_itcmSizeKBytes * 1024;
                uint32_t dtcm_size = KP_dtcmSizeKBytes * 1024;
                uint32_t dtcm_base = (KP_itcmSizeKBytes == 8 && KP_dtcmSizeKBytes == 32) ? 0x10000 : 0x100000;
                bool in_tcm = (addr < itcm_size) || (addr >= dtcm_base && addr < dtcm_base + dtcm_size);

                bool use_backdoor = this->backdoor_load_;
                if (use_backdoor && in_tcm) {
                  this->BackdoorLoad(addr, reinterpret_cast<const uint8_t*>(src), count);
                } else {
                  elf_transfers.push_back(utils::Write(
                      reinterpret_cast<uint64_t>(dest),
                      reinterpret_cast<uint8_t*>(const_cast<void*>(src)), count));
                  elf_transfers.push_back(
                      utils::Read(reinterpret_cast<uint64_t>(dest), count));
                  elf_transfers.push_back(utils::Expect(
                      reinterpret_cast<uint8_t*>(const_cast<void*>(src)), count));
                }
                return dest;
              });
    elf_transfers.push_back(utils::Write(
      csr_addr_ + 0x4, reinterpret_cast<uint8_t*>(&entry_point), sizeof(entry_point)
    ));
    transfer_queue_.push(
        std::make_unique<TrafficDesc>(utils::merge(elf_transfers)));
    uint32_t tohost;
    if (::LookupSymbol(data8, "tohost", &tohost)) {
      // NB: This alignment requirement is to simplify the watchpoint implementation.
      CHECK((tohost & 0xFFFFFFF0L) == tohost);
      tohost_addr_ = tohost;
    }
    uint32_t tohost_ready;
    if (::LookupSymbol(data8, "tohost_ready", &tohost_ready)) {
      tohost_ready_addr_ = tohost_ready;
    }
    uint32_t fromhost;
    if (::LookupSymbol(data8, "fromhost", &fromhost)) {
      fromhost_addr_ = fromhost;
    }
    uint32_t fromhost_ready;
    if (::LookupSymbol(data8, "fromhost_ready", &fromhost_ready)) {
      fromhost_ready_addr_ = fromhost_ready;
    }
  } else {
    // Transaction to fill ITCM with the provided binary.
    transfer_queue_.push(
        std::make_unique<TrafficDesc>(utils::merge(std::vector<DataTransfer>(
            {utils::Write(0, data8, file_size), utils::Read(0, file_size),
             utils::Expect(data8, file_size)}))));
  }
  munmap(file_data, file_size);
  return absl::OkStatus();
}

absl::Status CoreMiniAxi_tb::ClockGateSync(bool enable) {
  CHECK_OK(ClockGateAsync(enable));
  absl::MutexLock lock(transfer_queue_mtx_);
  transfer_queue_cv_.Wait(&transfer_queue_mtx_);
  return absl::OkStatus();
}

absl::Status CoreMiniAxi_tb::ClockGateAsync(bool enable) {
  absl::MutexLock lock(transfer_queue_mtx_);
  uint8_t enable8 = enable ? 3 : 1;
  uint8_t enable_[4] = { enable8, 0, 0, 0 };;
  transfer_queue_.push(
      std::make_unique<TrafficDesc>(utils::merge(std::vector<DataTransfer>(
          {utils::Write(csr_addr_, enable_),
           utils::Read(csr_addr_, 4),
           utils::Expect(enable_, 4)}))));
  return absl::OkStatus();
}

absl::Status CoreMiniAxi_tb::ResetSync(bool enable) {
  CHECK_OK(ResetAsync(enable));
  absl::MutexLock lock(transfer_queue_mtx_);
  transfer_queue_cv_.Wait(&transfer_queue_mtx_);
  return absl::OkStatus();
}

absl::Status CoreMiniAxi_tb::ResetAsync(bool enable) {
  absl::MutexLock lock(transfer_queue_mtx_);
  uint8_t enable8 = enable ? 1 : 0;
  uint8_t enable_[4] = { enable8, 0, 0, 0 };;
  transfer_queue_.push(
      std::make_unique<TrafficDesc>(utils::merge(std::vector<DataTransfer>(
          {utils::Write(csr_addr_, enable_),
           utils::Read(csr_addr_, 4),
           utils::Expect(enable_, 4)}))));
  return absl::OkStatus();
}

absl::Status CoreMiniAxi_tb::CheckStatusSync() {
  CHECK_OK(CheckStatusAsync());
  absl::MutexLock lock(transfer_queue_mtx_);
  transfer_queue_cv_.Wait(&transfer_queue_mtx_);
  return absl::OkStatus();
}

absl::Status CoreMiniAxi_tb::CheckStatusAsync() {
  absl::MutexLock lock(transfer_queue_mtx_);
  transfer_queue_.push(std::make_unique<TrafficDesc>(utils::merge(
      std::vector<DataTransfer>({utils::Read(csr_addr_ + 0x8, 4),
                                 utils::Expect(DATA(1, 0, 0, 0), 4)}))));
  return absl::OkStatus();
}

void CoreMiniAxi_tb::TraceInstructions() {
#define TRACE_INSTRUCTION(x) do { \
  uint32_t pc, inst, idx; \
  pc = debug_io_.rb_inst_##x##_bits_pc.read().get_word(0); \
  inst = debug_io_.rb_inst_##x##_bits_inst.read().get_word(0); \
  idx = debug_io_.rb_inst_##x##_bits_idx.read().get_word(0); \
  bool trap = debug_io_.rb_inst_##x##_bits_trap.read(); \
  if (debug_io_.rb_inst_##x##_valid.read()) { \
    auto data = debug_io_.rb_inst_##x##_bits_data.read(); \
    std::vector<uint8_t> data_vec(data.length() / 8); \
    int num_words = data.length() / 32; \
    for (int i = 0; i < num_words; ++i) { \
      uint32_t word = data.get_word((num_words - 1) - i); \
      data_vec[i*4+0] = (word >> 24) & 0xff; \
      data_vec[i*4+1] = (word >> 16) & 0xff; \
      data_vec[i*4+2] = (word >> 8) & 0xff; \
      data_vec[i*4+3] = word & 0xff; \
    } \
    tracer_.TraceInstructionRaw(pc, inst, idx, data_vec, trap); \
  } \
} while (0);
  REPEAT(TRACE_INSTRUCTION, KP_retirementLanes);
#undef TRACE_INSTRUCTION
}

void CoreMiniAxi_tb::tohost_reader_thread() {
  while (true) {
    wait(tohost_read_event_);
    uint64_t addr = tohost_read_addr_;

    tlm::tlm_generic_payload trans;
    sc_time delay = SC_ZERO_TIME;

    if (addr == 0 && tohost_addr_.has_value()) {
      // Triggered by tohost_ready. Read the actual payload from tohost.
      uint64_t tohost_payload = 0;
      trans.set_command(tlm::TLM_READ_COMMAND);
      trans.set_address(tohost_addr_.value());
      trans.set_data_ptr(reinterpret_cast<uint8_t*>(&tohost_payload));
      trans.set_data_length(8);
      trans.set_streaming_width(8);
      trans.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
      delay = SC_ZERO_TIME;
      tohost_initiator_socket_->b_transport(trans, delay);

      if (tohost_payload & 1) {
        tohost_halt = true;
        tohost_val = static_cast<uint32_t>(tohost_payload);
        continue;
      }
      addr = tohost_payload;
    }

    if (addr == 0) continue;

    uint8_t data[64];

    trans.set_command(tlm::TLM_READ_COMMAND);
    trans.set_address(addr);
    trans.set_data_ptr(data);
    trans.set_data_length(64);
    trans.set_streaming_width(64);
    trans.set_byte_enable_ptr(nullptr);
    trans.set_dmi_allowed(false);
    trans.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);

    tohost_initiator_socket_->b_transport(trans, delay);

    uint64_t resp_val = 0;
    if (trans.is_response_error()) {
      LOG(ERROR) << "tohost read error at " << std::hex << addr << ": " << trans.get_response_string();
    } else {
      // Clear tohost to acknowledge receipt of the address.
      if (tohost_addr_.has_value()) {
        uint64_t zero64 = 0;
        trans.set_command(tlm::TLM_WRITE_COMMAND);
        trans.set_address(tohost_addr_.value());
        trans.set_data_ptr(reinterpret_cast<uint8_t*>(&zero64));
        trans.set_data_length(8);
        trans.set_streaming_width(8);
        trans.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
        delay = SC_ZERO_TIME;
        tohost_initiator_socket_->b_transport(trans, delay);
      }

      uint64_t words[8];
      memcpy(words, data, sizeof(words));
      switch (words[0]) {
        case 56:  // sys_openat
        {
          int64_t dirfd_guest = static_cast<int64_t>(words[1]);
          int dirfd = (dirfd_guest == -100) ? AT_FDCWD : static_cast<int>(dirfd_guest);
          auto iter = fd_map_.find(words[1]);
          if (iter != fd_map_.end()) {
            dirfd = iter->second;
          }
          uint64_t name_addr = words[2];
          size_t name_len = static_cast<size_t>(words[3]);
          int flags = static_cast<int>(words[4]);
          int mode = static_cast<int>(words[5]);

          std::vector<char> name(name_len + 1, 0);
          trans.set_command(tlm::TLM_READ_COMMAND);
          trans.set_address(name_addr);
          trans.set_data_ptr(reinterpret_cast<uint8_t*>(name.data()));
          trans.set_data_length(name_len);
          trans.set_streaming_width(name_len);
          trans.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
          delay = SC_ZERO_TIME;
          tohost_initiator_socket_->b_transport(trans, delay);
          if (trans.is_response_error()) {
            resp_val = -1;
          } else {
            int host_flags = 0;
            if (flags & 0x0001) host_flags |= O_WRONLY;
            if (flags & 0x0002) host_flags |= O_RDWR;
            if (flags & 0x0200) host_flags |= O_CREAT;
            if (flags & 0x0400) host_flags |= O_TRUNC;
            if (flags & 0x0800) host_flags |= O_EXCL;
            if (flags & 0x4000) host_flags |= O_APPEND;

            int host_fd = openat(dirfd, name.data(), host_flags, mode);
            if (host_fd >= 0) {
              resp_val = host_fd + 3; // Offset to avoid overlapping with stdio
              fd_map_[resp_val] = host_fd;
            } else {
              resp_val = -1;
            }
          }
        } break;

        case 57:  // sys_close
        {
          uint64_t guest_fd = words[1];
          auto iter = fd_map_.find(guest_fd);
          if (iter != fd_map_.end()) {
            resp_val = close(iter->second);
            fd_map_.erase(iter);
          } else {
            resp_val = -1;
          }
        } break;

        case 62:  // sys_lseek
        {
          uint64_t guest_fd = words[1];
          auto iter = fd_map_.find(guest_fd);
          int host_fd = (iter == fd_map_.end()) ? -1 : iter->second;
          off_t offset = static_cast<off_t>(words[2]);
          int whence = static_cast<int>(words[3]);
          resp_val = lseek(host_fd, offset, whence);
        } break;

        case 63:  // sys_read
        {
          uint64_t guest_fd = words[1];
          uint64_t buf_addr = words[2];
          size_t buf_len = static_cast<size_t>(words[3]);
          std::vector<uint8_t> buf(buf_len);
          ssize_t bytes_read;
          if (guest_fd == 0) {
            bytes_read = read(0, buf.data(), buf_len);
          } else {
            auto iter = fd_map_.find(guest_fd);
            int host_fd = (iter == fd_map_.end()) ? -1 : iter->second;
            bytes_read = read(host_fd, buf.data(), buf_len);
          }

          if (bytes_read > 0) {
            trans.set_command(tlm::TLM_WRITE_COMMAND);
            trans.set_address(buf_addr);
            trans.set_data_ptr(buf.data());
            trans.set_data_length(bytes_read);
            trans.set_streaming_width(bytes_read);
            trans.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
            delay = SC_ZERO_TIME;
            tohost_initiator_socket_->b_transport(trans, delay);
            if (trans.is_response_error()) {
              LOG(ERROR) << "sys_read buf write error at " << std::hex << buf_addr;
              resp_val = -1;
            } else {
              resp_val = bytes_read;
            }
          } else {
            resp_val = bytes_read;
          }
        } break;

        case 64:  // sys_write
        {
          uint64_t guest_fd = words[1];
          uint64_t buf_addr = words[2];
          size_t buf_len = static_cast<size_t>(words[3]);
          std::vector<uint8_t> buf(buf_len);
          trans.set_command(tlm::TLM_READ_COMMAND);
          trans.set_address(buf_addr);
          trans.set_data_ptr(buf.data());
          trans.set_data_length(buf_len);
          trans.set_streaming_width(buf_len);
          trans.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
          delay = SC_ZERO_TIME;
          tohost_initiator_socket_->b_transport(trans, delay);
          if (trans.is_response_error()) {
            LOG(ERROR) << "sys_write buf read error at " << std::hex << buf_addr;
            resp_val = -1;
          } else {
            if (guest_fd == 1 || guest_fd == 2) {
              std::string s(reinterpret_cast<char*>(buf.data()), buf_len);
              std::cout << s << std::flush;
              resp_val = buf_len;
            } else {
              auto iter = fd_map_.find(guest_fd);
              int host_fd = (iter == fd_map_.end()) ? -1 : iter->second;
              resp_val = write(host_fd, buf.data(), buf_len);
            }
          }
        } break;

        case 67:  // sys_pread
        {
          uint64_t guest_fd = words[1];
          auto iter = fd_map_.find(guest_fd);
          int host_fd = (iter == fd_map_.end()) ? -1 : iter->second;
          uint64_t buf_addr = words[2];
          size_t buf_len = static_cast<size_t>(words[3]);
          off_t offset = static_cast<off_t>(words[4]);
          std::vector<uint8_t> buf(buf_len);
          ssize_t bytes_read = pread(host_fd, buf.data(), buf_len, offset);
          if (bytes_read > 0) {
            trans.set_command(tlm::TLM_WRITE_COMMAND);
            trans.set_address(buf_addr);
            trans.set_data_ptr(buf.data());
            trans.set_data_length(bytes_read);
            trans.set_streaming_width(bytes_read);
            trans.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
            delay = SC_ZERO_TIME;
            tohost_initiator_socket_->b_transport(trans, delay);
            if (trans.is_response_error()) {
              LOG(ERROR) << "sys_pread buf write error at " << std::hex << buf_addr;
              resp_val = -1;
            } else {
              resp_val = bytes_read;
            }
          } else {
            resp_val = bytes_read;
          }
        } break;

        case 68:  // sys_pwrite
        {
          uint64_t guest_fd = words[1];
          auto iter = fd_map_.find(guest_fd);
          int host_fd = (iter == fd_map_.end()) ? -1 : iter->second;
          uint64_t buf_addr = words[2];
          size_t buf_len = static_cast<size_t>(words[3]);
          off_t offset = static_cast<off_t>(words[4]);
          std::vector<uint8_t> buf(buf_len);
          trans.set_command(tlm::TLM_READ_COMMAND);
          trans.set_address(buf_addr);
          trans.set_data_ptr(buf.data());
          trans.set_data_length(buf_len);
          trans.set_streaming_width(buf_len);
          trans.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
          delay = SC_ZERO_TIME;
          tohost_initiator_socket_->b_transport(trans, delay);
          if (trans.is_response_error()) {
            LOG(ERROR) << "sys_pwrite buf read error at " << std::hex << buf_addr;
            resp_val = -1;
          } else {
            resp_val = pwrite(host_fd, buf.data(), buf_len, offset);
          }
        } break;

        case 93:  // sys_exit
          tohost_halt = true;
          tohost_val = words[1];
          break;

        case 2011:  // sys_getmainvars
        {
          uint64_t buf_addr = words[1];
          uint64_t limit = words[2];
          uint64_t argc = 1;
          const char* arg0 = "coralnpu.elf";
          uint64_t arg0_addr = buf_addr + 16; // Place string after argc and argv[0] pointer
          std::vector<uint64_t> packet(2);
          packet[0] = argc;
          packet[1] = arg0_addr;
          if (limit >= (16 + strlen(arg0) + 1)) {
            // Write argc and argv pointers
            trans.set_command(tlm::TLM_WRITE_COMMAND);
            trans.set_address(buf_addr);
            trans.set_data_ptr(reinterpret_cast<uint8_t*>(packet.data()));
            trans.set_data_length(16);
            trans.set_streaming_width(16);
            trans.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
            delay = SC_ZERO_TIME;
            tohost_initiator_socket_->b_transport(trans, delay);

            // Write the string
            trans.set_command(tlm::TLM_WRITE_COMMAND);
            trans.set_address(arg0_addr);
            trans.set_data_ptr(reinterpret_cast<uint8_t*>(const_cast<char*>(arg0)));
            trans.set_data_length(strlen(arg0) + 1);
            trans.set_streaming_width(strlen(arg0) + 1);
            trans.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
            tohost_initiator_socket_->b_transport(trans, delay);

            resp_val = 0; // Success
          } else {
            resp_val = -1;
          }
        } break;

        default:
          resp_val = -1;
          break;
      }
    }

    // Write return code back to the first word of the packet.
    // Use 32-bit writes to be safe with the 32-bit core's bus.
    uint32_t resp_low = static_cast<uint32_t>(resp_val);
    uint32_t resp_high = static_cast<uint32_t>(resp_val >> 32);

    trans.set_command(tlm::TLM_WRITE_COMMAND);
    trans.set_address(addr);
    trans.set_data_ptr(reinterpret_cast<uint8_t*>(&resp_low));
    trans.set_data_length(4);
    trans.set_streaming_width(4);
    trans.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
    delay = SC_ZERO_TIME;
    tohost_initiator_socket_->b_transport(trans, delay);

    trans.set_address(addr + 4);
    trans.set_data_ptr(reinterpret_cast<uint8_t*>(&resp_high));
    tohost_initiator_socket_->b_transport(trans, delay);

    // Write completion response to fromhost.
    if (fromhost_addr_.has_value()) {
      // libgloss-htif htif_syscall polls for fromhost != 0.
      // After it sees != 0, it clears fromhost.
      uint32_t resp_low = 1;
      uint32_t resp_high = 0;

      trans.set_command(tlm::TLM_WRITE_COMMAND);
      trans.set_address(fromhost_addr_.value());
      trans.set_data_ptr(reinterpret_cast<uint8_t*>(&resp_low));
      trans.set_data_length(4);
      trans.set_streaming_width(4);
      trans.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
      delay = SC_ZERO_TIME;
      tohost_initiator_socket_->b_transport(trans, delay);

      trans.set_address(fromhost_addr_.value() + 4);
      trans.set_data_ptr(reinterpret_cast<uint8_t*>(&resp_high));
      tohost_initiator_socket_->b_transport(trans, delay);
    }

    if (fromhost_ready_addr_.has_value()) {
      uint64_t one64 = 1;
      trans.set_command(tlm::TLM_WRITE_COMMAND);
      trans.set_address(fromhost_ready_addr_.value());
      trans.set_data_ptr(reinterpret_cast<uint8_t*>(&one64));
      trans.set_data_length(8);
      trans.set_streaming_width(8);
      trans.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
      delay = SC_ZERO_TIME;
      tohost_initiator_socket_->b_transport(trans, delay);
    }

    // Clear tohost_ready if present.
    if (tohost_ready_addr_.has_value()) {
      uint64_t zero64 = 0;
      trans.set_command(tlm::TLM_WRITE_COMMAND);
      trans.set_address(tohost_ready_addr_.value());
      trans.set_data_ptr(reinterpret_cast<uint8_t*>(&zero64));
      trans.set_data_length(8);
      trans.set_streaming_width(8);
      trans.set_response_status(tlm::TLM_INCOMPLETE_RESPONSE);
      delay = SC_ZERO_TIME;
      tohost_initiator_socket_->b_transport(trans, delay);
    }
  }
}

void CoreMiniAxi_tb::posedge() {
  const bool core_io_dbus_valid = debug_io_.dbus_valid;
  const bool core_io_dbus_write = debug_io_.dbus_bits_write;
  const uint32_t core_io_dbus_addr = debug_io_.dbus_bits_addr.read().get_word(0);

  // If we have tohost_ready, trigger only when it's written with 1.
  if (tohost_ready_addr_.has_value() && core_io_dbus_valid && core_io_dbus_write && (core_io_dbus_addr == tohost_ready_addr_.value())) {
    const uint32_t wdata0 = debug_io_.dbus_bits_wdata.read().get_word(0);
    if (wdata0 != 1) return;

    // We trigger the read event, which will read from 'tohost' symbol address.
    // The tohost_reader_thread already uses tohost_read_addr_ which we should update here.
    // Wait, the tohost_reader_thread uses tohost_read_addr_ set in posedge.
    // We need to READ the current value of tohost from memory.
    // But posedge() shouldn't do bus transactions.
    // Let's modify tohost_reader_thread to read tohost if it's not provided.
    tohost_read_addr_ = 0; // Signal to thread to read 'tohost' from its known address
    tohost_read_event_.notify();
    return;
  }

  // Fallback/Legacy support: trigger on tohost write if tohost_ready is not present.
  if (!tohost_ready_addr_.has_value() && tohost_addr_.has_value() && core_io_dbus_valid && core_io_dbus_write && (core_io_dbus_addr == tohost_addr_.value())) {
    const uint32_t wdata0 = debug_io_.dbus_bits_wdata.read().get_word(0);
    if (wdata0 == 0) return;
    if (wdata0 & 1) {
      tohost_halt = true;
      tohost_val = wdata0;
    } else {
      tohost_read_addr_ = wdata0;
      tohost_read_event_.notify();
    }
  }

  if (instr_trace_) {
    TraceInstructions();
  }

  static bool invoked_halted_cb = false;
  if ((io_halted || io_fault || tohost_halt) && !invoked_halted_cb) {
    // If instruction tracing is enabled,
    // print the data about the instruction trace.
    if (instr_trace_) {
      tracer_.PrintTrace();
    }
    invoked_halted_cb = true;
    if (halted_cb_) {
      halted_cb_.value()();
    }
  }

  static bool wfi_seen = false;
  if (io_wfi && !wfi_seen) {
    io_irq = true;
    wfi_seen = true;
    if (wfi_cb_) {
      wfi_cb_.value()();
    }
  } else if (!io_wfi && wfi_seen) {
    io_irq = false;
    wfi_seen = false;
  } else {
    io_irq = false;
  }


  if (!transfer_in_progress_) {
    absl::MutexLock lock(transfer_queue_mtx_);
    if (!transfer_queue_.empty()) {
      ITrafficDesc* transfer = transfer_queue_.front().get();
      tg_.addTransfers(transfer, 0, CoreMiniAxi_tb::axi_transaction_done_cb);
      transfer_in_progress_ = true;
    }
  }
}

void CoreMiniAxi_tb::EnqueueTransactionSync(
    std::vector<DataTransfer> transfers) {
  EnqueueTransactionAsync(transfers);
  absl::MutexLock lock(transfer_queue_mtx_);
  transfer_queue_cv_.Wait(&transfer_queue_mtx_);
}

void CoreMiniAxi_tb::EnqueueTransactionAsync(
    std::vector<DataTransfer> transfers) {
  absl::MutexLock lock_(transfer_queue_mtx_);
  transfer_queue_.push(std::make_unique<TrafficDesc>(utils::merge(transfers)));
}

void CoreMiniAxi_tb::axi_transaction_done_cb(TLMTrafficGenerator* gen,
                                             int threadId) {
  getSingleton()->axi_transaction_done_cb_(gen, threadId);
}

void CoreMiniAxi_tb::axi_transaction_done_cb_(TLMTrafficGenerator* gen,
                                              int threadId) {
  absl::MutexLock lock(transfer_queue_mtx_);
  CHECK(!transfer_queue_.empty());
  transfer_queue_.pop();
  transfer_in_progress_ = false;
  transfer_queue_cv_.SignalAll();
}

CoreMiniAxi_tb* CoreMiniAxi_tb::singleton_ = nullptr;

void CoreMiniAxi_tb::BackdoorLoad(uint64_t addr, const uint8_t* data, size_t len) {
  CHECK(coralnpu::SramBackdoorLoad(addr, data, len));
}
