# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import cocotb
import itertools
import math
import numpy as np
import os
import random

from coralnpu_test_utils.backdoor import backdoor_load
from cocotb.clock import Clock
from cocotb.handle import LogicObject, LogicArrayObject, Immediate
from cocotb.queue import Queue
from cocotb.triggers import Timer, ClockCycles, RisingEdge, FallingEdge
from elftools.elf.elffile import ELFFile


class AxiResp:
  OKAY = 0
  EXOKAY = 1
  SLVERR = 2
  DECERR = 3


class AxiBurst:
  FIXED = 0
  INCR = 1
  WRAP = 2


class DmReqOp:
  NOP = 0
  READ = 1
  WRITE = 2
  RSVD = 3


class DmRspOp:
  SUCCESS = 0
  RSVD = 1
  FAILED = 2
  BUSY = 3


class DmCmdType:
  ACCESS_REGISTER = 0
  QUICK_ACCESS = 1
  ACCESS_MEMORY = 2


# See RISC-V Debug Specification v0.13.2
class DmAddress:
  DATA0       = 0x04
  DATA1       = 0x05
  DMCONTROL   = 0x10
  DMSTATUS    = 0x11
  HARTINFO    = 0x12
  ABSTRACTCS  = 0x16
  COMMAND     = 0x17


class DebugCsrAddr:
  REQ_ADDR   = 0x800
  REQ_DATA   = 0x804
  REQ_OP     = 0x808
  RSP_DATA   = 0x80C
  RSP_OP     = 0x810
  STATUS     = 0x814


def format_line_from_word(word, addr):
  shift = addr % 16
  line = np.zeros([4], dtype=np.uint32)
  line[0] = word
  line = np.roll(line.view(np.uint8), shift)
  return convert_to_binary_value(line)

def pad_to_multiple(x, multiple):
  padding = multiple - (len(x) % multiple)
  if padding == multiple:
    return x
  return np.pad(x, (0, padding))

def get_strb(mask):
  val = 0
  for m in reversed(mask):
    val = val << 1
    if m:
      val += 1
  return val

def convert_to_binary_value(data):
  return cocotb.types.LogicArray.from_bytes(data, byteorder="little")


def set_x(signal):
  if isinstance(signal, LogicObject):
    signal.value = "X"
  elif isinstance(signal, LogicArrayObject):
    signal.value = "X" * len(signal.range)
  else:
    raise TypeError(f"Unsupported signal type for set_x: {type(signal)}")


class ReadyValidInterface:
  def __init__(self, dut, prefix):
    self.valid_signal = dut[f'{prefix}_valid']
    self.bits_signals = {}
    for k, v in dut._items():
      signal_prefix = f'{prefix}_bits_'
      if k.startswith(signal_prefix):
        self.bits_signals[k.removeprefix(signal_prefix)] = v
    self.ready_signal = dut[f'{prefix}_ready']

  def clear_valid(self):
    self.valid_signal.value = 0
    for _, s in self.bits_signals.items():
      set_x(s)

  def set_valid(self, bits):
    self.valid_signal.value = 1
    for k, v in bits.items():
      self.bits_signals[k].value = v


# This class simulates a memory-mapped AXI interface. Programs compiled with
# the `coralnpu_v2_binary` rule will have access to TCM (Tightly-Coupled Memory)
# and simulated external memory (`EXTMEM`).
#
# The `EXTMEM` block is located at `0x20000000`.
#
# TCM sizes can be customized by setting `itcm_size_kbytes` or
# `dtcm_size_kbytes` in the `coralnpu_v2_binary` rule.
#
# For example:
#
# coralnpu_v2_binary(
#     name = "my_test.elf",
#     srcs = ["my_test.c"],
#     itcm_size_kbytes = 1024,
#     dtcm_size_kbytes = 1024,
# )
class CoreMiniAxiInterface:
  def __init__(self,
               dut,
               clock_ns=1.25,
               csr_base_addr=0x30000,
               ext_mem_base_addr = 0x20000000,
               ext_mem_size=(4 * 1024 * 1024),
               **kwargs):
    # Allow overriding clock_ns from plusargs or environment.
    if "CLOCK_NS" in cocotb.plusargs:
      clock_ns = float(cocotb.plusargs["CLOCK_NS"])
    elif "COCOTB_CLOCK_NS" in os.environ:
      clock_ns = float(os.environ["COCOTB_CLOCK_NS"])

    self.dut = dut
    self.dut.io_aclk.value = 0
    self.dut.io_irq.value = 0
    self.dut.io_timer_irq.value = 0
    self.dut.io_software_irq.value = 0
    self.dut.io_te.value = 0
    self.dut.io_boot_addr.value = 0
    # We drive the DM directly via the CSR route.
    self.dut.io_dm_req_valid.value = 0
    self.dut.io_dm_rsp_ready.value = 0
    self.axi_slave_read_addr = ReadyValidInterface(
        self.dut, "io_axi_slave_read_addr")
    self.axi_slave_read_addr.clear_valid()
    self.dut.io_axi_slave_read_data_ready.value = 0
    self.axi_slave_write_addr = ReadyValidInterface(
        self.dut, "io_axi_slave_write_addr")
    self.axi_slave_write_addr.clear_valid()
    self.axi_slave_write_data = ReadyValidInterface(
        self.dut, "io_axi_slave_write_data")
    self.axi_slave_write_data.clear_valid()
    self.dut.io_axi_slave_write_resp_ready.value = 0
    self.axi_master_read_data = ReadyValidInterface(
        self.dut, "io_axi_master_read_data")
    self.axi_master_read_data.clear_valid()
    self.axi_master_write_resp = ReadyValidInterface(
        self.dut, "io_axi_master_write_resp")
    self.axi_master_write_resp.clear_valid()
    self.clock_ns = clock_ns
    self.clock = Clock(dut.io_aclk, clock_ns, unit="ns")
    self.csr_base_addr = csr_base_addr
    self.memory_base_addr = ext_mem_base_addr
    self.memory = np.zeros([ext_mem_size], dtype=np.uint8)
    self.master_arfifo = Queue()
    self.master_awfifo = Queue()
    self.master_rfifo = Queue()
    self.master_wfifo = Queue()
    self.master_bfifo = Queue()
    self.slave_arfifo = Queue()
    self.slave_awfifo = Queue()
    self.slave_rfifo = Queue()
    self.slave_wfifo = Queue()
    self.slave_bfifo = Queue()

  async def init(self):
    cocotb.start_soon(self._monitor_agent())
    cocotb.start_soon(self.master_ragent())
    cocotb.start_soon(self.master_bagent())
    cocotb.start_soon(self.slave_awagent())
    cocotb.start_soon(self.slave_wagent())
    cocotb.start_soon(self.slave_aragent())
    cocotb.start_soon(self.memory_write_agent())
    cocotb.start_soon(self.memory_read_agent())

  async def read_csr(self, addr):
    val = await self.read_word(self.csr_base_addr + addr)
    return val

  async def write_csr(self, addr, data):
    await self.write_word(self.csr_base_addr + addr, data)

  def _get_aamsize(self, size_bytes: int) -> int:
    # aamsize: 0=byte, 1=half-word, 2=word (corresponding to size_bytes 1, 2, 4)
    aamsize = 0
    if size_bytes == 1:
        aamsize = 0
    elif size_bytes == 2:
        aamsize = 1
    elif size_bytes == 4:
        aamsize = 2
    else:
        assert False, f"Unsupported memory access size: {size_bytes} bytes"
    return aamsize

  async def slave_awagent(self, timeout=4096):
    self.axi_slave_write_addr.clear_valid()
    while True:
      awdata = await self.slave_awfifo.get()
      await RisingEdge(self.dut.io_aclk)
      self.axi_slave_write_addr.set_valid(awdata)
      timeout_count = 0
      while True:
        await FallingEdge(self.dut.io_aclk)
        if self.axi_slave_write_addr.ready_signal.value:
          break
        timeout_count += 1
        if timeout_count >= timeout:
          assert False, "timeout waiting for awready"
        await RisingEdge(self.dut.io_aclk)
      if self.slave_awfifo.empty():
        await RisingEdge(self.dut.io_aclk)
        self.axi_slave_write_addr.clear_valid()

  async def slave_wagent(self, timeout=4096):
    self.axi_slave_write_data.clear_valid()
    while True:
      wdata = await self.slave_wfifo.get()
      await RisingEdge(self.dut.io_aclk)
      self.axi_slave_write_data.set_valid(wdata)
      timeout_count = 0
      while True:
        await FallingEdge(self.dut.io_aclk)
        if self.axi_slave_write_data.ready_signal.value:
          break
        timeout_count += 1
        if timeout_count >= timeout:
          assert False, "timeout waiting for wready"
        await RisingEdge(self.dut.io_aclk)
      if self.slave_wfifo.empty():
        await RisingEdge(self.dut.io_aclk)
        self.axi_slave_write_data.clear_valid()

  async def _monitor_agent(self):
    self.dut.io_axi_slave_write_resp_ready.value = 1
    self.dut.io_axi_slave_read_data_ready.value = 1
    self.dut.io_axi_master_read_addr_ready.value = 1
    self.dut.io_axi_master_write_addr_ready.value = 1
    self.dut.io_axi_master_write_data_ready.value = 1
    while True:
      await RisingEdge(self.dut.io_aclk)
      # slave_bagent
      if self.dut.io_axi_slave_write_resp_valid.value:
        try:
          bdata = dict()
          bdata["id"] = self.dut.io_axi_slave_write_resp_bits_id
          bdata["resp"] = self.dut.io_axi_slave_write_resp_bits_resp
          await self.slave_bfifo.put(bdata)
        except Exception as e:
          print("X seen in slave_bagent: " + str(e))

      # slave_ragent
      if self.dut.io_axi_slave_read_data_valid.value:
        try:
          rdata = dict()
          val = self.dut.io_axi_slave_read_data_bits_data.value
          if val.is_resolvable:
            rdata["data"] = np.frombuffer(val.to_bytes(byteorder="big"), dtype=np.uint8)
          else:
            nonx_data = val.binstr.replace("X", "0").replace("z", "0")
            rdata["data"] = np.array([int(nonx_data[i:i+8], 2) for i in range(0, len(nonx_data), 8)], dtype=np.uint8)
          rdata["id"] = self.dut.io_axi_slave_read_data_bits_id.value
          rdata["last"] = self.dut.io_axi_slave_read_data_bits_last.value
          rdata["resp"] = self.dut.io_axi_slave_read_data_bits_resp.value
          await self.slave_rfifo.put(rdata)
        except Exception as e:
          print("X seen in slave_ragent: " + str(e))

      # master_aragent
      if self.dut.io_axi_master_read_addr_valid.value:
        try:
          ardata = dict()
          ardata["id"] = self.dut.io_axi_master_read_addr_bits_id.value.to_unsigned()
          ardata["addr"] = self.dut.io_axi_master_read_addr_bits_addr.value.to_unsigned()
          ardata["size"] = self.dut.io_axi_master_read_addr_bits_size.value.to_unsigned()
          ardata["len"] = self.dut.io_axi_master_read_addr_bits_len.value.to_unsigned()
          ardata["burst"] = self.dut.io_axi_master_read_addr_bits_burst.value.to_unsigned()
          await self.master_arfifo.put(ardata)
        except Exception as e:
          print("X seen in master_aragent: " + str(e))
          raise e

      # master_awagent
      if self.dut.io_axi_master_write_addr_valid.value:
        try:
          awdata = dict()
          awdata["id"] = self.dut.io_axi_master_write_addr_bits_id.value.to_unsigned()
          awdata["addr"] = self.dut.io_axi_master_write_addr_bits_addr.value.to_unsigned()
          awdata["size"] = self.dut.io_axi_master_write_addr_bits_size.value.to_unsigned()
          awdata["len"] = self.dut.io_axi_master_write_addr_bits_len.value.to_unsigned()
          await self.master_awfifo.put(awdata)
        except Exception as e:
          print("X seen in master_awagent: " + str(e))

      # master_wagent
      if self.dut.io_axi_master_write_data_valid.value:
        try:
          wdata = dict()
          wdata["data"] = self.dut.io_axi_master_write_data_bits_data.value.to_bytes(byteorder="big")
          wdata["strb"] = self.dut.io_axi_master_write_data_bits_strb.value
          wdata["last"] = self.dut.io_axi_master_write_data_bits_last.value
          await self.master_wfifo.put(wdata)
        except Exception as e:
          print("X seen in master_wagent: " + str(e))

  async def slave_aragent(self, timeout=4096):
    self.axi_slave_read_addr.clear_valid()
    while True:
      ardata = await self.slave_arfifo.get()
      await RisingEdge(self.dut.io_aclk)
      self.axi_slave_read_addr.set_valid(ardata)
      timeout_count = 0
      while True:
        await FallingEdge(self.dut.io_aclk)
        if self.axi_slave_read_addr.ready_signal.value:
          break
        timeout_count += 1
        if timeout_count >= timeout:
          assert False, "timeout waiting for arready"
        await RisingEdge(self.dut.io_aclk)
      if self.slave_arfifo.empty():
        await RisingEdge(self.dut.io_aclk)
        self.axi_slave_read_addr.clear_valid()

  async def memory_read_agent(self):
    while True:
      ardata = await self.master_arfifo.get()
      data = self.read_memory(ardata)
      if data is None:
        for i in range(0, ardata["len"] + 1):
          rdata = dict()
          rdata["id"] = ardata["id"]
          rdata["data"] = 0
          rdata["resp"] = AxiResp.SLVERR
          rdata["last"] = 1 if (i == ardata["len"]) else 0
          await self.master_rfifo.put(rdata)
      else:
        for i in range(0, ardata["len"] + 1):
          rdata = dict()
          rdata["id"] = ardata["id"]
          rdata["data"] = convert_to_binary_value(data)
          rdata["resp"] = AxiResp.OKAY
          rdata["last"] = 1 if (i == ardata["len"]) else 0
          await self.master_rfifo.put(rdata)

  async def master_ragent(self, timeout=4096):
    self.axi_master_read_data.clear_valid()
    while True:
      rdata = await self.master_rfifo.get()
      await RisingEdge(self.dut.io_aclk)
      self.axi_master_read_data.set_valid(rdata)
      timeout_count = 0
      while True:
        await FallingEdge(self.dut.io_aclk)
        if self.axi_master_read_data.ready_signal.value:
          break
        timeout_count += 1
        if timeout_count >= timeout:
          assert False, "timeout waiting for rready"
        await RisingEdge(self.dut.io_aclk)
      if self.master_rfifo.empty():
        await RisingEdge(self.dut.io_aclk)
        self.axi_master_read_data.clear_valid()

  async def memory_write_agent(self):
    while True:
      awdata = await self.master_awfifo.get()
      data = []
      strb = []
      while True:
        wdata = await self.master_wfifo.get()
        line = np.frombuffer(wdata["data"], dtype=np.uint8)
        data.append(list(reversed(line)))
        strb.append(list(reversed(wdata["strb"])))
        if wdata["last"]:
          break
      assert len(data) == awdata["len"] + 1
      assert len(strb) == awdata["len"] + 1
      ret = self.write_memory({
          "addr": awdata["addr"],
          "size": awdata["size"],
          "len": awdata["len"],
          "data": data,
          "strb": strb,
      })
      bdata = dict()
      bdata["id"] = awdata["id"]
      bdata["resp"] = AxiResp.OKAY if ret else AxiResp.SLVERR
      await self.master_bfifo.put(bdata)

  async def master_bagent(self, timeout=4096):
    self.axi_master_write_resp.clear_valid()
    while True:
      bdata = await self.master_bfifo.get()
      await RisingEdge(self.dut.io_aclk)
      self.axi_master_write_resp.set_valid(bdata)
      timeout_count = 0
      while True:
        await FallingEdge(self.dut.io_aclk)
        if self.axi_master_write_resp.ready_signal.value:
          break
        timeout_count += 1
        if timeout_count >= timeout:
          assert False, "timeout waiting for bready"
        await RisingEdge(self.dut.io_aclk)
      if self.master_bfifo.empty():
        await RisingEdge(self.dut.io_aclk)
        self.axi_master_write_resp.clear_valid()

  async def reset(self):
    self.dut.io_aresetn.set(Immediate(1))
    await Timer(self.clock_ns, unit="ns")
    self.dut.io_aresetn.set(Immediate(0))
    await Timer(self.clock_ns, unit="ns")
    self.dut.io_aresetn.set(Immediate(1))
    await Timer(self.clock_ns, unit="ns")

  async def halt(self):
    coralnpu_reset_csr_addr = self.csr_base_addr
    await self.write_word(coralnpu_reset_csr_addr, 3)

  async def _poll_dm_status(self, bit, value, retries=100):
    while True:
      status = await self.read_csr(DebugCsrAddr.STATUS)
      if (status[0] & (1 << bit)) == value:
        break
      await ClockCycles(self.dut.io_aclk, 10)
      retries -= 1
      if retries == 0:
        assert False, "Failed to reach requested DMSTATUS"

  async def dm_read(self, addr):
    await self._poll_dm_status(0, 1)

    await self.write_csr(DebugCsrAddr.REQ_ADDR, addr)
    await self.write_csr(DebugCsrAddr.REQ_DATA, 0)
    await self.write_csr(DebugCsrAddr.REQ_OP, DmReqOp.READ)

    await self._poll_dm_status(1, 2)

    rsp = dict()
    rsp["data"] = int((await self.read_csr(DebugCsrAddr.RSP_DATA)).view(np.uint32)[0])
    rsp["op"] = (await self.read_csr(DebugCsrAddr.RSP_OP)).view(np.uint32)[0]
    await self.write_csr(DebugCsrAddr.STATUS, 0)  # Acknowledge response.

    assert rsp["op"] == DmRspOp.SUCCESS
    return rsp["data"]

  async def dm_write(self, addr, data):
    await self._poll_dm_status(0, 1)

    await self.write_csr(DebugCsrAddr.REQ_ADDR, addr)
    await self.write_csr(DebugCsrAddr.REQ_DATA, data)
    await self.write_csr(DebugCsrAddr.REQ_OP, DmReqOp.WRITE)

    await self._poll_dm_status(1, 2)

    rsp = dict()
    rsp["data"] = int((await self.read_csr(DebugCsrAddr.RSP_DATA)).view(np.uint32)[0])
    rsp["op"] = (await self.read_csr(DebugCsrAddr.RSP_OP)).view(np.uint32)[0]
    await self.write_csr(DebugCsrAddr.STATUS, 0)  # Acknowledge response.
    return rsp

  async def dm_read_mem(self, addr, size_bytes, expected_op=DmRspOp.SUCCESS):
    # Set data1 to the target address for memory access
    rsp = await self.dm_write(DmAddress.DATA1, addr)
    assert rsp["op"] == DmRspOp.SUCCESS

    # Construct the memory access command
    aamsize = self._get_aamsize(size_bytes)
    command = (DmCmdType.ACCESS_MEMORY << 24) | \
              (aamsize << 20) | \
              (1 << 17)
    rsp = await self.dm_write(DmAddress.COMMAND, command)
    assert rsp["op"] == expected_op
    if rsp["op"] != DmRspOp.SUCCESS:
        return 0

    data = await self.dm_read(DmAddress.DATA0)
    status = await self.dm_read(DmAddress.ABSTRACTCS)
    cmderr = (status >> 8) & 0b111
    assert (cmderr == 0)
    return data

  async def dm_write_mem(self, addr, data, size_bytes, expected_op=DmRspOp.SUCCESS):
    # Set data1 to the target address for memory access
    rsp = await self.dm_write(DmAddress.DATA1, addr)
    assert rsp["op"] == DmRspOp.SUCCESS

    # Set data0 to the value to write
    rsp = await self.dm_write(DmAddress.DATA0, data)
    assert rsp["op"] == DmRspOp.SUCCESS

    # Construct the memory access command
    aamsize = self._get_aamsize(size_bytes)
    command = (DmCmdType.ACCESS_MEMORY << 24) | \
              ((aamsize & 0b111) << 20) | \
              (1 << 16) | \
              (1 << 17)
    rsp = await self.dm_write(DmAddress.COMMAND, command)
    assert rsp["op"] == expected_op
    if rsp["op"] != DmRspOp.SUCCESS:
        return

    status = await self.dm_read(DmAddress.ABSTRACTCS)
    cmderr = (status >> 8) & 0b111
    assert (cmderr == 0)

  async def dm_read_reg(self, addr, expected_op=DmRspOp.SUCCESS):
    command = ((DmCmdType.ACCESS_REGISTER << 24) & 0xFF) | (((2 << 20) | (1 << 17) | (addr)) & 0xFFFFFF)
    rsp = await self.dm_write(DmAddress.COMMAND, command)
    assert rsp["op"] == expected_op
    if rsp["op"] != DmRspOp.SUCCESS:
        return 0

    data = await self.dm_read(DmAddress.DATA0)
    status = await self.dm_read(DmAddress.ABSTRACTCS)
    cmderr = (status >> 8) & 0b111
    assert (cmderr == 0)
    return data

  async def dm_write_reg(self, addr, data):
    rsp = await self.dm_write(DmAddress.DATA0, data)
    assert rsp["op"] == DmRspOp.SUCCESS
    command = ((DmCmdType.ACCESS_REGISTER << 24) & 0xFF) | (((2 << 20) | (1 << 17) | (1 << 16) | addr) & 0xFFFFFF)
    rsp = await self.dm_write(DmAddress.COMMAND, command)
    assert rsp["op"] == DmRspOp.SUCCESS
    status = await self.dm_read(DmAddress.ABSTRACTCS)
    cmderr = (status >> 8) & 0b111
    assert (cmderr == 0)

  async def dm_request_halt(self):
    dmcontrol = await self.dm_read(DmAddress.DMCONTROL)
    dmcontrol = dmcontrol | (1 << 31) & ~(1 << 30)
    return await self.dm_write(DmAddress.DMCONTROL, dmcontrol)

  async def dm_check_for_halted(self):
        dmstatus = await self.dm_read(DmAddress.DMSTATUS)
        allhalted = dmstatus & (1 << 9)
        anyhalted = dmstatus & (1 << 8)
        if allhalted and anyhalted:
          return True
        return False

  async def dm_wait_for_halted(self, retry_count=100):
    retries = 0
    while True:
        dmstatus = await self.dm_read(DmAddress.DMSTATUS)
        allhalted = dmstatus & (1 << 9)
        anyhalted = dmstatus & (1 << 8)
        if allhalted and anyhalted:
            break
        retries += 1
        assert retries < retry_count

  async def dm_request_resume(self):
    dmcontrol = await self.dm_read(DmAddress.DMCONTROL)
    dmcontrol = dmcontrol | (1 << 30) & ~(1 << 31)
    await self.dm_write(DmAddress.DMCONTROL, dmcontrol)

  async def dm_wait_for_resumed(self, retry_count=100):
    retries = 0
    while True:
        dmstatus = await self.dm_read(DmAddress.DMSTATUS)
        allrunning = dmstatus & (1 << 11)
        anyrunning = dmstatus & (1 << 10)
        if allrunning and anyrunning:
            break
        retries += 1
        assert retries < retry_count

  async def debug_req(self):
    await RisingEdge(self.dut.io_aclk)
    self.dut.io_debug_req.value = 1
    await RisingEdge(self.dut.io_aclk)
    self.dut.io_debug_req.value = 0

  async def _write_addr(self, addr, size, burst_len=1, axi_id=0, burst=AxiBurst.INCR):
    awdata = dict()
    awdata["addr"] = addr
    awdata["id"] = axi_id
    awdata["len"] = burst_len - 1
    awdata["size"] = size
    awdata["burst"] = burst
    await self.slave_awfifo.put(awdata)

  async def _wait_write_response(self, delay_bready: int = 0):
    self.dut.io_axi_slave_write_resp_ready.value = 0
    if delay_bready:
      await ClockCycles(self.dut.io_aclk, delay_bready)
    self.dut.io_axi_slave_write_resp_ready.value = 1
    timeout_cycles = 100
    cyclesawaited = 0
    while self.dut.io_axi_slave_write_resp_valid.value != 1 and \
          timeout_cycles > 0:
       await ClockCycles(self.dut.io_aclk, 1)
       cyclesawaited += 1
       timeout_cycles = timeout_cycles - 1
    assert timeout_cycles > 0
    if cyclesawaited == 0:
      await ClockCycles(self.dut.io_aclk, 1)
    self.dut.io_axi_slave_write_resp_ready.value = 0

  async def _write_data_beat(self, data, mask, last):
    """Writes one beat to the write data line."""
    assert len(data) % 16 == 0
    assert len(mask) % 16 == 0
    wdata = dict()
    wdata["data"] = convert_to_binary_value(data)
    wdata["strb"] = get_strb(mask)
    wdata["last"] = last
    await self.slave_wfifo.put(wdata)

  def _determine_transaction_size(self, addr: int, data_len: int) -> int:
    # Transactions cannot cross 4k boundary
    offset4096 = addr % 4096
    remainder4096 = 4096 - offset4096
    # Max transaction size is 256 beats * 16 bytes, but cannot cross 4kB boundary
    max_transaction_size_bytes = min(4096, remainder4096)
    return min(data_len, max_transaction_size_bytes)

  async def _write_data(self, addr, data, masks, beats):
    beats_sent = 0
    while len(data) > 0:
      base_addr = (addr // 16) * 16
      sub_addr = addr - base_addr
      bytes_to_write = 16 - sub_addr
      bytes_to_write = min(len(data), bytes_to_write)
      local_data = data[0:bytes_to_write]
      local_data = np.pad(local_data, (sub_addr, 0))
      local_data = pad_to_multiple(local_data, 16)
      local_masks = masks[0:bytes_to_write]
      local_masks = np.pad(local_masks, (sub_addr, 0))
      local_masks = pad_to_multiple(local_masks, 16)
      data = data[bytes_to_write:]
      masks = masks[bytes_to_write:]
      last = (len(data) == 0)
      # TODO(derekjchow): Insert RNG delays
      await self._write_data_beat(local_data, local_masks, last)
      addr = addr + bytes_to_write
      beats_sent = beats_sent + 1
    assert beats_sent == beats

  async def _write_transaction(self,
                               addr: int,
                               data: np.array,
                               masks: np.array,
                               delay_bready: int = 0,
                               axi_id: int = 0,
                               burst: AxiBurst = AxiBurst.INCR) -> None:
    # Compute number of beats
    start_addr = addr
    end_addr = addr + len(data) - 1 # Last address written
    start_line = start_addr // 16
    end_line = end_addr // 16
    beats = (end_line - start_line) + 1
    # Compute size of transaction
    # TODO(derekjchow): Fuzz element size?
    write_addr_size = math.ceil(math.log2(len(data)))
    write_addr_size = min(write_addr_size, 4) # Size of 16 for increment
    write_addr_task = self._write_addr(addr, write_addr_size, beats, axi_id, burst)
    write_data_task = self._write_data(addr, data, masks, beats)
    await write_addr_task
    await write_data_task
    bdata = await self.slave_bfifo.get()
    assert bdata["id"].value == axi_id

  async def _axi_valid_memory_addr(self, addr, data_len) -> bool:
    return (addr >= self.memory_base_addr) and (addr + data_len < self.memory_base_addr + len(self.memory))

  async def write(self,
                  addr: int,
                  data: np.array,
                  delay_bready: int = 0,
                  masks: np.array = None,
                  burst: AxiBurst = AxiBurst.INCR) -> None:
    """Writes data into CoralNPU memory."""
    axi_id = random.randint(0,63)
    data = data.view(np.uint8)
    if masks is None:
      masks = np.copy(np.ones_like(data, dtype=bool))
    while len(data) > 0:
      transaction_size = self._determine_transaction_size(addr, len(data))
      local_data = data[0:transaction_size]
      local_masks = masks[0:transaction_size]
      if await self._axi_valid_memory_addr(addr, len(local_data)):
        for i in range(len(local_data)):
          self.memory[addr - self.memory_base_addr + i] = local_data[i]
      else:
        await self._write_transaction(addr, local_data, local_masks, delay_bready, axi_id, burst)
      addr += len(local_data)
      data = data[transaction_size:]
      masks = masks[transaction_size:]

  async def write_word(self, addr: int, data: int) -> None:
    axi_id = random.randint(0,63)
    await self.write(addr, np.array([data], dtype=np.uint32), axi_id)

  async def _read_addr(self,
                       addr: int,
                       size: int,
                       beats: int = 1,
                       axi_id: int = 0,
                       burst: AxiBurst = AxiBurst.INCR):
    ardata = dict()
    ardata["addr"] = addr
    ardata["id"] = axi_id
    ardata["len"] = beats - 1
    ardata["size"] = size
    ardata["burst"] = burst
    await self.slave_arfifo.put(ardata)

  async def _read_data(self, expected_resp=AxiResp.OKAY, axi_id=0):
    rdata = await self.slave_rfifo.get()
    data = rdata["data"]
    last = rdata["last"]
    assert rdata["resp"] == expected_resp
    assert rdata["id"] == axi_id

    return last, np.flip(data)

  async def _read_transaction(self,
                              addr: int,
                              bytes_to_read: int,
                              expected_resp: AxiResp = AxiResp.OKAY,
                              axi_id: int = 0,
                              burst: AxiBurst = AxiBurst.INCR):
    # Compute number of beats
    start_addr = addr
    end_addr = addr + bytes_to_read - 1 # Last address written
    start_line = start_addr // 16
    end_line = end_addr // 16
    beats = (end_line - start_line) + 1
    await self._read_addr(start_line * 16, 4, beats, axi_id, burst)
    data = []
    bytes_remaining = bytes_to_read
    for beat in range(beats):
      base_addr = (addr // 16) * 16
      sub_addr = addr - base_addr
      (last, beat_data) = await self._read_data(expected_resp, axi_id)
      beat_data = beat_data[sub_addr:]
      if len(beat_data) > bytes_remaining:
        beat_data = beat_data[0:bytes_remaining]
      data.append(beat_data)
      bytes_remaining = bytes_remaining - len(beat_data)
      addr = addr + len(beat_data)
      if beat == (beats - 1):
        assert last
    return np.concatenate(data)

  async def read(self, addr, bytes_to_read, burst: AxiBurst=AxiBurst.INCR):
    """Reads data from CoralNPU Memory."""
    axi_id = random.randint(0,63)
    data = []
    while bytes_to_read > 0:
      transaction_size = self._determine_transaction_size(addr, bytes_to_read)
      if await self._axi_valid_memory_addr(addr, transaction_size):
        rel_addr = addr - self.memory_base_addr
        data.append(self.memory[rel_addr : rel_addr + transaction_size])
      else:
        data.append(await self._read_transaction(addr, transaction_size, 0, axi_id, burst))
      bytes_to_read -= transaction_size
      addr += transaction_size
    if len(data) == 0 :
      return data
    return np.concatenate(data)

  async def read_word(self, addr, expected_resp=AxiResp.OKAY):
    axi_id = random.randint(0,63)
    data = []
    offset = addr % 16
    await self._read_addr(addr, 4, 1, axi_id)
    (last, beat_data) = await self._read_data(expected_resp, axi_id)
    assert (last == True)
    data.append(beat_data[offset:offset+4])
    return np.concatenate(data)

  async def load_elf(self, f, backdoor: bool = True):
    """Loads an ELF into DUT memory and returns the entry point.

    Defaults to the fast `load_elf_backdoor` path. Pass `backdoor=False` to
    force the classic AXI bus-write path (`load_elf_axi`) for tests that
    specifically exercise frontdoor loading.
    """
    # Check environment variable override
    if os.environ.get("COCOTB_USE_FRONTDOOR") == "1":
      backdoor = False

    if backdoor:
      return await self.load_elf_backdoor(f)
    return await self.load_elf_axi(f)

  async def load_elf_axi(self, f):
    """Loads an ELF file into DUT memory via AXI bus writes (frontdoor),
    and returns the entry point address."""
    elf_file = ELFFile(f)
    entry_point = elf_file.header["e_entry"]
    for segment in elf_file.iter_segments(type="PT_LOAD"):
      header = segment.header
      data = np.frombuffer(segment.data(), dtype=np.uint8)
      if self._axi_memory_contains(header["p_paddr"]) and \
         self._axi_memory_contains(header["p_paddr"] + len(data) -1):
        memory_start = header["p_paddr"] - self.memory_base_addr
        memory_end = memory_start + len(data)
        self.memory[memory_start:memory_end] = data
        continue
      await self.write(header["p_paddr"], data)
    return entry_point

  async def load_elf_backdoor(self, f):
    """Loads an ELF file into DUT memory via backdoor, and returns the entry point address.

    Segments landing in the testbench-side AXI slave region (`self.memory`)
    are written directly to that numpy array — matching `load_elf_axi`'s
    handling. The DPI `sram_backdoor_load_c` only reaches Chisel-emitted
    SRAMs inside the DUT, not the Python AxiSlave model.
    """
    elf_file = ELFFile(f)
    entry_point = elf_file.header["e_entry"]
    for segment in elf_file.iter_segments(type="PT_LOAD"):
      header = segment.header
      data = np.frombuffer(segment.data(), dtype=np.uint8)
      if len(data) == 0:
        continue
      if self._axi_memory_contains(header["p_paddr"]) and \
         self._axi_memory_contains(header["p_paddr"] + len(data) - 1):
        memory_start = header["p_paddr"] - self.memory_base_addr
        memory_end = memory_start + len(data)
        self.memory[memory_start:memory_end] = data
        continue
      self.dut._log.info(f"Backdoor loading {len(data)} bytes to 0x{header['p_paddr']:08x}")
      backdoor_load(header["p_paddr"], data)
    return entry_point

  def _axi_memory_contains(self, x):
    """Checks if an address is contained in the AXI memory region"""
    return (x >= self.memory_base_addr) and \
        (x < (self.memory_base_addr + len(self.memory)))

  def lookup_symbol(self, f, symbol_name):
    elf_file = ELFFile(f)
    symtab_section = next(elf_file.iter_sections(type='SHT_SYMTAB'))
    i1 = symtab_section.get_symbol_by_name(symbol_name)
    if i1:
      return i1[0].entry['st_value']
    return None

  def write_memory(self, wdata):
    """Write `wdata` to memory."""
    addr = int(wdata["addr"])
    data = wdata["data"]
    strb = wdata["strb"]
    if addr < self.memory_base_addr or addr >= (self.memory_base_addr + len(self.memory)):
      return False
    line_start = (addr - self.memory_base_addr) & 0xFFFFFFF0
    flat_data = list(itertools.chain(*data))
    flat_strb = list(itertools.chain(*strb))
    for i in range(0,len(flat_data)):
      if flat_strb[i] == 1:
        self.memory[line_start + i] = flat_data[i]
    return True

  def read_memory(self, raddr):
    addr = int(raddr["addr"])
    size = (2 ** raddr["size"])
    if addr < self.memory_base_addr or addr >= (self.memory_base_addr + len(self.memory)):
      return None
    offset = (addr - self.memory_base_addr)
    data = self.memory[offset:offset+size]
    padded_data = pad_to_multiple(data, 16)
    line_shift = addr % 16
    return np.roll(padded_data.view(np.uint8), line_shift)

  async def execute_from(self, start_pc):
    # Program starting address
    coralnpu_pc_csr_addr = self.csr_base_addr + 4
    await self.write_word(coralnpu_pc_csr_addr, start_pc)
    # Release clock gate
    coralnpu_reset_csr_addr = self.csr_base_addr
    await self.write_word(coralnpu_reset_csr_addr, 1)
    # Release reset
    await self.write_word(coralnpu_reset_csr_addr, 0)

  async def wait_for_wfi(self):
    if self.dut.io_wfi.value != 1:
      await RisingEdge(self.dut.io_wfi)

  async def raise_irq(self, cycles=1):
    self.dut.io_irq.value = 1
    await ClockCycles(self.dut.io_aclk, cycles)
    self.dut.io_irq.value = 0

  async def wait_for_halted(self, timeout_cycles=1000):
    cycle_count = 0
    while self.dut.io_halted.value != 1 and timeout_cycles > 0:
      await ClockCycles(self.dut.io_aclk, 1)
      timeout_cycles = timeout_cycles - 1
      cycle_count += 1
    assert timeout_cycles > 0
    return cycle_count

  async def wait_for_halted_semihost(self, elf, timeout_cycles=1000000):
    tohost = self.lookup_symbol(elf, "tohost")
    assert tohost != None
    initial_rv = await self.read_word(tohost)
    while True:
      await RisingEdge(self.dut.io_aclk)
      rv = await self.read_word(tohost)
      if not (rv == initial_rv).all():
        assert np.sum(rv) == 1
        break
      timeout_cycles = timeout_cycles - 1
      assert timeout_cycles > 0

  async def wait_for_fault(self, timeout_cycles=1000):
    cycle_count = 0
    while self.dut.io_fault.value != 1 and timeout_cycles > 0:
      await ClockCycles(self.dut.io_aclk, 1)
      timeout_cycles = timeout_cycles - 1
      cycle_count += 1
    assert timeout_cycles > 0
    return cycle_count
