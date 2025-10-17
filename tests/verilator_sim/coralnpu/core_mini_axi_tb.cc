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
                               std::optional<std::function<void()>> wfi_cb,
                               std::optional<std::function<void()>> halted_cb)
    : Sysc_tb(n, loops, random),
      tg_("traffic_generator"),
      tlm2axi_bridge_("tlm2axi_bridge"),
      axi2tlm_bridge_("axi2tlm_bridge"),
      tlm2axi_checker_("tlm2axi_checker"),
      tlm2axi_signals_("tlm2axi_signals"),
      axi2tlm_signals_("axi2tlm_signals"),
      xbar_("xbar"),
      wfi_cb_(wfi_cb),
      halted_cb_(halted_cb),
      instr_trace_(instr_trace) {
  if (CoreMiniAxi_tb::singleton_ != nullptr) {
    CHECK(false);
  }
  CoreMiniAxi_tb::singleton_ = this;
  core_ = std::make_unique<VERILATOR_MODEL>("core");

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

  tg_.setStartDelay(sc_time(5, SC_NS));
  tg_.socket.bind(tlm2axi_bridge_.tgt_socket);
  if (debug_axi) {
    tg_.enableDebug();
  }

  axi2tlm_bridge_.socket.bind(xbar_.socket());
}

CoreMiniAxi_tb::~CoreMiniAxi_tb() { singleton_ = nullptr; }

void CoreMiniAxi_tb::Connect() {
  core_->io_aclk(clock);
  core_->io_aresetn(resetn);
  core_->io_halted(io_halted);
  core_->io_fault(io_fault);
  core_->io_wfi(io_wfi);
  core_->io_irq(io_irq);
  core_->io_te(io_te);

  core_->io_slog_valid(slog_io_.valid);
  core_->io_slog_addr(slog_io_.addr);
  core_->io_slog_data(slog_io_.data);

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
#if (KP_useRetirementBuffer == true)
#define BIND_RB_DEBUG_IO(x) \
  core_->io_debug_rb_inst_##x##_valid(debug_io_.rb_inst_##x##_valid); \
  core_->io_debug_rb_inst_##x##_bits_pc(debug_io_.rb_inst_##x##_bits_pc); \
  core_->io_debug_rb_inst_##x##_bits_inst(debug_io_.rb_inst_##x##_bits_inst); \
  core_->io_debug_rb_inst_##x##_bits_idx(debug_io_.rb_inst_##x##_bits_idx); \
  core_->io_debug_rb_inst_##x##_bits_data(debug_io_.rb_inst_##x##_bits_data);
  REPEAT(BIND_RB_DEBUG_IO, KP_retirementBufferSize);
#undef BIND_RB_DEBUG_IO
#endif
#if (KP_useDebugModule == true)
  core_->io_dm_req_valid(dm_io_.req_valid);
  core_->io_dm_req_ready(dm_io_.req_valid);
  core_->io_dm_req_bits_address(dm_io_.req_bits_address);
  core_->io_dm_req_bits_data(dm_io_.req_bits_data);
  core_->io_dm_req_bits_op(dm_io_.req_bits_op);
  core_->io_dm_rsp_valid(dm_io_.rsp_valid);
  core_->io_dm_rsp_ready(dm_io_.rsp_valid);
  core_->io_dm_rsp_bits_data(dm_io_.rsp_bits_data);
  core_->io_dm_rsp_bits_op(dm_io_.rsp_bits_op);
#endif

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
  absl::MutexLock lock(&transfer_queue_mtx_);
  transfer_queue_cv_.Wait(&transfer_queue_mtx_);
  return absl::OkStatus();
}

absl::Status CoreMiniAxi_tb::LoadElfAsync(const std::string& file_name) {
  absl::MutexLock lock(&transfer_queue_mtx_);
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
              [&elf_transfers](void* dest, const void* src, size_t count) {
                elf_transfers.push_back(utils::Write(
                    reinterpret_cast<uint64_t>(dest),
                    reinterpret_cast<uint8_t*>(const_cast<void*>(src)), count));
                elf_transfers.push_back(
                    utils::Read(reinterpret_cast<uint64_t>(dest), count));
                elf_transfers.push_back(utils::Expect(
                    reinterpret_cast<uint8_t*>(const_cast<void*>(src)), count));
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
    uint32_t fromhost;
    if (::LookupSymbol(data8, "fromhost", &fromhost)) {
      fromhost_addr_ = fromhost;
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
  absl::MutexLock lock(&transfer_queue_mtx_);
  transfer_queue_cv_.Wait(&transfer_queue_mtx_);
  return absl::OkStatus();
}

absl::Status CoreMiniAxi_tb::ClockGateAsync(bool enable) {
  absl::MutexLock lock(&transfer_queue_mtx_);
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
  absl::MutexLock lock(&transfer_queue_mtx_);
  transfer_queue_cv_.Wait(&transfer_queue_mtx_);
  return absl::OkStatus();
}

absl::Status CoreMiniAxi_tb::ResetAsync(bool enable) {
  absl::MutexLock lock(&transfer_queue_mtx_);
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
  absl::MutexLock lock(&transfer_queue_mtx_);
  transfer_queue_cv_.Wait(&transfer_queue_mtx_);
  return absl::OkStatus();
}

absl::Status CoreMiniAxi_tb::CheckStatusAsync() {
  absl::MutexLock lock(&transfer_queue_mtx_);
  transfer_queue_.push(std::make_unique<TrafficDesc>(utils::merge(
      std::vector<DataTransfer>({utils::Read(csr_addr_ + 0x8, 4),
                                 utils::Expect(DATA(1, 0, 0, 0), 4)}))));
  return absl::OkStatus();
}

void CoreMiniAxi_tb::TraceInstructions() {
#if (KP_useRetirementBuffer == true)
#define TRACE_INSTRUCTION(x) do { \
  uint32_t pc, inst, idx; \
  pc = debug_io_.rb_inst_##x##_bits_pc.read().get_word(0); \
  inst = debug_io_.rb_inst_##x##_bits_inst.read().get_word(0); \
  idx = debug_io_.rb_inst_##x##_bits_idx.read().get_word(0); \
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
    tracer_.TraceInstructionRaw(pc, inst, idx, data_vec); \
  } \
} while (0);
REPEAT(TRACE_INSTRUCTION, KP_retirementBufferSize);
#undef TRACE_INSTRUCTION
#else
  std::vector<bool> instFires = {
    debug_io_.dispatch_0_instFire.read(),
    debug_io_.dispatch_1_instFire.read(),
    debug_io_.dispatch_2_instFire.read(),
    debug_io_.dispatch_3_instFire.read()
  };
  std::vector<uint32_t> instAddrs = {
    debug_io_.dispatch_0_instAddr.read().get_word(0),
    debug_io_.dispatch_1_instAddr.read().get_word(0),
    debug_io_.dispatch_2_instAddr.read().get_word(0),
    debug_io_.dispatch_3_instAddr.read().get_word(0)
  };
  std::vector<uint32_t> instInsts = {
    debug_io_.dispatch_0_instInst.read().get_word(0),
    debug_io_.dispatch_1_instInst.read().get_word(0),
    debug_io_.dispatch_2_instInst.read().get_word(0),
    debug_io_.dispatch_3_instInst.read().get_word(0)
  };
  std::vector<bool> scalarWriteAddrValids = {
    debug_io_.regfile_writeAddr_0_valid.read(),
    debug_io_.regfile_writeAddr_1_valid.read(),
    debug_io_.regfile_writeAddr_2_valid.read(),
    debug_io_.regfile_writeAddr_3_valid.read()
  };
  std::vector<uint32_t> scalarWriteAddrAddrs = {
    debug_io_.regfile_writeAddr_0_bits.read().get_word(0),
    debug_io_.regfile_writeAddr_1_bits.read().get_word(0),
    debug_io_.regfile_writeAddr_2_bits.read().get_word(0),
    debug_io_.regfile_writeAddr_3_bits.read().get_word(0)
  };
  std::vector<bool> floatWriteAddrValids = {
    debug_io_.float_writeAddr_valid.read()
  };
  std::vector<uint32_t> floatWriteAddrAddrs = {
    debug_io_.float_writeAddr_bits.read().get_word(0)
  };

  std::vector<bool> writeDataValids = {
    debug_io_.regfile_writeData_0_valid.read(),
    debug_io_.regfile_writeData_1_valid.read(),
    debug_io_.regfile_writeData_2_valid.read(),
    debug_io_.regfile_writeData_3_valid.read(),
    debug_io_.regfile_writeData_4_valid.read(),
    debug_io_.regfile_writeData_5_valid.read(),
    debug_io_.float_writeData_0_valid.read(),
    debug_io_.float_writeData_1_valid.read()
  };

  std::vector<uint32_t> writeDataAddrs = {
    debug_io_.regfile_writeData_0_bits_addr.read().get_word(0),
    debug_io_.regfile_writeData_1_bits_addr.read().get_word(0),
    debug_io_.regfile_writeData_2_bits_addr.read().get_word(0),
    debug_io_.regfile_writeData_3_bits_addr.read().get_word(0),
    debug_io_.regfile_writeData_4_bits_addr.read().get_word(0),
    debug_io_.regfile_writeData_5_bits_addr.read().get_word(0),
    debug_io_.float_writeData_0_bits_addr.read().get_word(0),
    debug_io_.float_writeData_1_bits_addr.read().get_word(0)
  };

  std::vector<uint32_t> writeDataDatas = {
    debug_io_.regfile_writeData_0_bits_data.read().get_word(0),
    debug_io_.regfile_writeData_1_bits_data.read().get_word(0),
    debug_io_.regfile_writeData_2_bits_data.read().get_word(0),
    debug_io_.regfile_writeData_3_bits_data.read().get_word(0),
    debug_io_.regfile_writeData_4_bits_data.read().get_word(0),
    debug_io_.regfile_writeData_5_bits_data.read().get_word(0),
    debug_io_.float_writeData_0_bits_data.read().get_word(0),
    debug_io_.float_writeData_1_bits_data.read().get_word(0)
  };

  std::vector<int> executeRegBases = {
    InstructionTrace::kScalarBaseReg,
    InstructionTrace::kScalarBaseReg,
    InstructionTrace::kScalarBaseReg,
    InstructionTrace::kScalarBaseReg,
    InstructionTrace::kScalarBaseReg,
    InstructionTrace::kScalarBaseReg,
    InstructionTrace::kFloatBaseReg,
    InstructionTrace::kFloatBaseReg
  };

  tracer_.TraceInstruction(
    instFires,
    instAddrs,
    instInsts,
    scalarWriteAddrValids,
    scalarWriteAddrAddrs,
    floatWriteAddrValids,
    floatWriteAddrAddrs,
    writeDataValids,
    writeDataAddrs,
    writeDataDatas,
    executeRegBases
  );
#endif
}

void CoreMiniAxi_tb::posedge() {
  const bool core_io_dbus_valid = debug_io_.dbus_valid;
  const bool core_io_dbus_write = debug_io_.dbus_bits_write;
  const uint32_t core_io_dbus_addr = debug_io_.dbus_bits_addr.read().get_word(0);
  if (tohost_addr_.has_value() && core_io_dbus_valid && core_io_dbus_write && (core_io_dbus_addr == tohost_addr_.value())) {
    const uint32_t wdata0 = debug_io_.dbus_bits_wdata.read().get_word(0);
    if (wdata0 & 1) {
      tohost_halt = true;
      tohost_val = wdata0;
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
    absl::MutexLock lock(&transfer_queue_mtx_);
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
  absl::MutexLock lock(&transfer_queue_mtx_);
  transfer_queue_cv_.Wait(&transfer_queue_mtx_);
}

void CoreMiniAxi_tb::EnqueueTransactionAsync(
    std::vector<DataTransfer> transfers) {
  absl::MutexLock lock_(&transfer_queue_mtx_);
  transfer_queue_.push(std::make_unique<TrafficDesc>(utils::merge(transfers)));
}

void CoreMiniAxi_tb::axi_transaction_done_cb(TLMTrafficGenerator* gen,
                                             int threadId) {
  getSingleton()->axi_transaction_done_cb_(gen, threadId);
}

void CoreMiniAxi_tb::axi_transaction_done_cb_(TLMTrafficGenerator* gen,
                                              int threadId) {
  absl::MutexLock lock(&transfer_queue_mtx_);
  CHECK(!transfer_queue_.empty());
  transfer_queue_.pop();
  transfer_in_progress_ = false;
  transfer_queue_cv_.SignalAll();
}

CoreMiniAxi_tb* CoreMiniAxi_tb::singleton_ = nullptr;
