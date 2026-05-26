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
import glob
import numpy as np
import os
import tqdm
import random

from coralnpu_test_utils.core_mini_axi_interface import AxiBurst, AxiResp,CoreMiniAxiInterface
from coralnpu_test_utils.sim_test_fixture import Fixture
from bazel_tools.tools.python.runfiles import runfiles
from cocotb.triggers import ClockCycles


@cocotb.test()
async def core_mini_axi_basic_write_read_memory(dut):
    """Basic test to check if TCM memory can be written and read back."""
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())

    # Test reading/writing words
    await core_mini_axi.write_word(0x100, 0x42)
    await core_mini_axi.write_word(0x104, 0x43)
    rdata = (await core_mini_axi.read(0x100, 16)).view(np.uint32)
    assert (rdata[0:2] == np.array([0x42, 0x43])).all()

    # Three write/read data burst
    wdata = np.arange(48, dtype=np.uint8)
    await core_mini_axi.write(0x0, wdata)

    # Unaligned read, taking two bursts
    rdata = await core_mini_axi.read(0x8, 16)
    assert (np.arange(8, 24, dtype=np.uint8) == rdata).all()

    # Unaligned write, taking two bursts
    wdata = np.arange(20, dtype=np.uint8)
    await core_mini_axi.write(0x204, wdata)
    rdata = await core_mini_axi.read(0x200, 32)
    assert (wdata == rdata[4:24]).all()

    # Iterate over both TCMs with all valid AXI sizes
    for size in range(13):
      txn_bytes = 2 ** size
      wdata = np.random.randint(0, 255, txn_bytes, dtype=np.uint8)
      for i in tqdm.tqdm(range((8 * 1024) // txn_bytes)):
        await core_mini_axi.write(i * txn_bytes, wdata)
      for i in tqdm.tqdm(range((32 * 1024) // txn_bytes)):
        await core_mini_axi.write(0x10000 + (i * txn_bytes), wdata)

      for i in tqdm.tqdm(range((8 * 1024) // txn_bytes)):
        rdata = await core_mini_axi.read(i * txn_bytes, txn_bytes)
        assert(rdata == wdata).all()
      for i in tqdm.tqdm(range((32 * 1024) // txn_bytes)):
        rdata = await core_mini_axi.read(0x10000 + (i * txn_bytes), txn_bytes)
        assert(rdata == wdata).all()

@cocotb.test()
async def core_mini_axi_run_wfi_in_all_slots(dut):
    """Tests the WFI instruction in each of the 4 issue slots."""
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())
    r = runfiles.Create()

    for slot in range(0,4):
      with open(r.Rlocation(f"coralnpu_hw/tests/cocotb/wfi_slot_{slot}.elf"), "rb") as f:
        await core_mini_axi.reset()
        entry_point = await core_mini_axi.load_elf(f)
        await core_mini_axi.execute_from(entry_point)

        await core_mini_axi.wait_for_wfi()
        await core_mini_axi.raise_irq()
        await core_mini_axi.wait_for_halted()

@cocotb.test()
async def core_mini_axi_slow_bready(dut):
  """Test that BVALID stays high until BREADY is presented"""
  core_mini_axi = CoreMiniAxiInterface(dut)
  await core_mini_axi.init()
  await core_mini_axi.reset()
  cocotb.start_soon(core_mini_axi.clock.start())

  wdata = np.arange(16, dtype=np.uint8)
  for i in tqdm.trange(100):
    bready_delay = random.randint(0, 50)
    await core_mini_axi.write(i*32, wdata, delay_bready=bready_delay)

  for _ in tqdm.trange(100):
    rdata = await core_mini_axi.read(i*32, 16)
    assert (wdata == rdata).all()

@cocotb.test()
async def core_mini_axi_write_read_memory_stress_test(dut):
    """Stress test reading/writing from DTCM."""
    core_mini_axi = CoreMiniAxiInterface(dut)
    await core_mini_axi.init()
    await core_mini_axi.reset()
    cocotb.start_soon(core_mini_axi.clock.start())
    r = runfiles.Create()

    with open(r.Rlocation("coralnpu_hw/tests/cocotb/stress_test.elf"), "rb") as f:
      halt = core_mini_axi.lookup_symbol(f, "halt")
      dtcm_vec = core_mini_axi.lookup_symbol(f, "dtcm_vec")
      entry_point = await core_mini_axi.load_elf(f)
    await core_mini_axi.execute_from(entry_point)

    # Range for a DTCM buffer we can read/write too.
    DTCM_START = dtcm_vec
    DTCM_SIZE = 0x2000
    DTCM_END = DTCM_START + DTCM_SIZE
    dtcm_model_buffer = await core_mini_axi.read(DTCM_START, DTCM_SIZE)

    for i in tqdm.trange(1000):
      start_addr = random.randint(DTCM_START, DTCM_END-2)
      end_addr = random.randint(start_addr, DTCM_END-1)
      transaction_length = end_addr - start_addr

      if random.randint(0, 1) == 1:
        wdata = np.random.randint(0, 256, transaction_length, dtype=np.uint8)
        await core_mini_axi.write(start_addr, wdata)
        dtcm_model_buffer[start_addr-DTCM_START: end_addr-DTCM_START] = wdata
      else:
        expected = dtcm_model_buffer[start_addr-DTCM_START: end_addr-DTCM_START]
        rdata = await core_mini_axi.read(start_addr, transaction_length)
        assert (expected == rdata).all()

    await core_mini_axi.write_word(halt, 1)
    try:
      await core_mini_axi.wait_for_halted()
    except:
      await core_mini_axi.halt()

@cocotb.test()
async def core_mini_axi_master_write_alignment(dut):
  """Test data alignment during AXI master writes"""
  core_mini_axi = CoreMiniAxiInterface(dut)
  await core_mini_axi.init()
  await core_mini_axi.reset()
  cocotb.start_soon(core_mini_axi.clock.start())
  r = runfiles.Create()

  with open(r.Rlocation("coralnpu_hw/tests/cocotb/align_test.elf"), "rb") as f:
    entry_point = await core_mini_axi.load_elf(f)
    await core_mini_axi.execute_from(entry_point)

    await core_mini_axi.wait_for_halted()
    assert core_mini_axi.dut.io_fault.value == 0

@cocotb.test()
async def core_mini_axi_finish_txn_before_halt_test(dut):
  core_mini_axi = CoreMiniAxiInterface(dut)
  await core_mini_axi.init()
  await core_mini_axi.reset()
  cocotb.start_soon(core_mini_axi.clock.start())
  r = runfiles.Create()

  with open(r.Rlocation("coralnpu_hw/tests/cocotb/finish_txn_before_halt.elf"), "rb") as f:
    entry_point = await core_mini_axi.load_elf(f)
    await core_mini_axi.execute_from(entry_point)
    await core_mini_axi.wait_for_halted()

    assert (core_mini_axi.master_arfifo.qsize() + \
            core_mini_axi.master_rfifo.qsize() + \
            core_mini_axi.master_awfifo.qsize() + \
            core_mini_axi.master_wfifo.qsize() + \
            core_mini_axi.master_bfifo.qsize()) == 0

@cocotb.test()
async def core_mini_axi_riscv_tests(dut):
  core_mini_axi = CoreMiniAxiInterface(dut)
  await core_mini_axi.init()
  await core_mini_axi.reset()
  cocotb.start_soon(core_mini_axi.clock.start())
  r = runfiles.Create()

  riscv_test_path_template = "coralnpu_hw/third_party/riscv-tests/copy_riscv_tests_rv32{suffix}/riscv_tests_rv32{suffix}/isa"
  riscv_test_suites = ['ui', 'um', 'uzbb', 'uf']
  riscv_test_paths = [r.Rlocation(riscv_test_path_template.format(suffix=suffix)) for suffix in riscv_test_suites]
  riscv_test_elfs = [os.path.join(riscv_test_path, f) for riscv_test_path in riscv_test_paths for f in os.listdir(riscv_test_path) if not f.endswith(".dump")]
  with tqdm.tqdm(riscv_test_elfs) as t:
    for elf in t:
      t.set_postfix({"binary": os.path.basename(elf)})
      if 'fence_i' in elf:
        # This one likes to jump into DTCM. Can probably patch the ASM
        continue
      with open(elf, "rb") as f:
        await core_mini_axi.reset()
        entry_point = await core_mini_axi.load_elf(f)
        await core_mini_axi.execute_from(entry_point)
        await core_mini_axi.wait_for_halted(timeout_cycles=100_000)
        assert core_mini_axi.dut.io_fault.value == 0

@cocotb.test()
async def core_mini_axi_riscv_dv(dut):
  core_mini_axi = CoreMiniAxiInterface(dut)
  await core_mini_axi.init()
  await core_mini_axi.reset()
  cocotb.start_soon(core_mini_axi.clock.start())
  r = runfiles.Create()

  riscv_dv_path = r.Rlocation("coralnpu_hw/tests/cocotb/riscv-dv")
  riscv_dv_elfs = [os.path.join(riscv_dv_path, f) for f in os.listdir(riscv_dv_path) if f.endswith(".o")]
  with tqdm.tqdm(riscv_dv_elfs) as t:
    for elf in tqdm.tqdm(riscv_dv_elfs):
      t.set_postfix({"binary": os.path.basename(elf)})
      with open(elf, "rb") as f:
        await core_mini_axi.reset()
        entry_point = await core_mini_axi.load_elf(f)
        await core_mini_axi.execute_from(entry_point)
        await core_mini_axi.wait_for_halted_semihost(f)

@cocotb.test()
async def core_mini_axi_csr_test(dut):
  """Exercises the CoreAxiCSR module."""
  core_mini_axi = CoreMiniAxiInterface(dut)
  await core_mini_axi.init()
  await core_mini_axi.reset()
  cocotb.start_soon(core_mini_axi.clock.start())

  for _ in tqdm.tqdm(range(10000)):
    reset_csr_wdata = np.random.randint(0, 255, 4, dtype=np.uint8)
    await core_mini_axi.write(0x30000, reset_csr_wdata)
    reset_csr_rdata = await core_mini_axi.read_word(0x30000)
    assert (reset_csr_wdata == reset_csr_rdata).all()

  for _ in tqdm.tqdm(range(10000)):
    pc_start_csr_wdata = np.random.randint(0, 255, 4, dtype=np.uint8)
    await core_mini_axi.write(0x30004, pc_start_csr_wdata)
    pc_start_csr_rdata = await core_mini_axi.read_word(0x30004)
    assert (pc_start_csr_wdata == pc_start_csr_rdata).all()

  # Neither of these are valid CSRs, but this will exercise the top half of the wdata field.
  for _ in tqdm.tqdm(range(10000)):
    csr_wdata = np.random.randint(0, 255, 4, dtype=np.uint8)
    await core_mini_axi.write(0x30008, csr_wdata)
    await core_mini_axi.write(0x3000c, csr_wdata)

  status_reg_csr_rdata = await core_mini_axi.read_word(0x30008)
  # Because we write a random value to the reset CSR, it's possible
  # for this register to either be 0, 1, or 3.
  assert (status_reg_csr_rdata.view(np.uint32) <= 3)

  # Read valid CSRs
  for i in range(8):
    misc_csr_rdata = await core_mini_axi.read_word(0x30100 + (4 * i))
  # Read invalid CSRs, expect error response
  for i in range(3, 0x100 // 4):
    misc_csr_rdata = await core_mini_axi.read_word(0x30000 + (4 * i), expected_resp=AxiResp.SLVERR)
  for i in [i for i in range(9, 0x2000 // 4) if (0x100 + 4 * i) not in range(0x800, 0x818)]:
    misc_csr_rdata = await core_mini_axi.read_word(0x30100 + (4 * i), expected_resp=AxiResp.SLVERR)

@cocotb.test()
async def core_mini_axi_exceptions_test(dut):
  core_mini_axi = CoreMiniAxiInterface(dut)
  await core_mini_axi.init()
  await core_mini_axi.reset()
  cocotb.start_soon(core_mini_axi.clock.start())
  r = runfiles.Create()

  exceptions_path = r.Rlocation("coralnpu_hw/tests/cocotb/exceptions")
  exceptions_elfs = [os.path.join(exceptions_path, f) for f in os.listdir(exceptions_path) if f.endswith(".elf")]
  with tqdm.tqdm(exceptions_elfs) as t:
    for elf in tqdm.tqdm(exceptions_elfs):
      t.set_postfix({"binary": os.path.basename(elf)})
      with open(elf, "rb") as f:
        await core_mini_axi.reset()
        entry_point = await core_mini_axi.load_elf(f)
        await core_mini_axi.execute_from(entry_point)
        await core_mini_axi.wait_for_halted()
        assert core_mini_axi.dut.io_fault.value == 0

@cocotb.test()
async def rvv_exceptions_test(dut):
  if "Rvv" not in dut._name:
    dut._log.info("Skipping rvv_exceptions_test on non-RVV core")
    return

  core_mini_axi = CoreMiniAxiInterface(dut)
  await core_mini_axi.init()
  await core_mini_axi.reset()
  cocotb.start_soon(core_mini_axi.clock.start())
  r = runfiles.Create()

  elf = r.Rlocation("coralnpu_hw/tests/cocotb/vector_store_fault.elf")
  with open(elf, "rb") as f:
    await core_mini_axi.reset()
    entry_point = await core_mini_axi.load_elf(f)
    await core_mini_axi.execute_from(entry_point)
    await core_mini_axi.wait_for_halted(timeout_cycles=50000)
    assert core_mini_axi.dut.io_fault.value == 0

@cocotb.test()
async def core_mini_axi_coralnpu_isa_test(dut):
  core_mini_axi = CoreMiniAxiInterface(dut)
  await core_mini_axi.init()
  await core_mini_axi.reset()
  cocotb.start_soon(core_mini_axi.clock.start())
  r = runfiles.Create()

  coralnpu_isa_path = r.Rlocation("coralnpu_hw/tests/cocotb/coralnpu_isa")
  coralnpu_isa_elfs = [os.path.join(coralnpu_isa_path, f) for f in os.listdir(coralnpu_isa_path) if f.endswith(".elf")]
  for elf in tqdm.tqdm(coralnpu_isa_elfs):
    with open(elf, "rb") as f:
      await core_mini_axi.reset()
      entry_point = await core_mini_axi.load_elf(f)
      await core_mini_axi.execute_from(entry_point)
      await core_mini_axi.wait_for_halted()
      assert core_mini_axi.dut.io_fault.value == 0

@cocotb.test()
async def core_mini_axi_rand_instr_test(dut):
  core_mini_axi = CoreMiniAxiInterface(dut)
  await core_mini_axi.init()
  await core_mini_axi.reset()
  cocotb.start_soon(core_mini_axi.clock.start())

  # Zero out memory to avoid xprop issues on jump instructions.
  await core_mini_axi.write(0, np.ones(0x2000, dtype=np.uint8))

  for _ in tqdm.tqdm(range(1000)):
    instr = np.random.randint(0, 2**32, 1, dtype=np.uint32)
    mpause = np.array([0x8000073], dtype=np.uint32)
    # For our instruction stream, set mpause as instr 0.
    # If we have an exception, we should jump to 0 due to
    # the default `mtvec` being 0, and halt.
    wdata = np.concatenate([mpause, instr, mpause, mpause])
    await core_mini_axi.reset()
    await core_mini_axi.write(0, wdata)
    await core_mini_axi.execute_from(4)
    try:
      await core_mini_axi.wait_for_halted(timeout_cycles=100)
    except:
      await core_mini_axi.halt()

@cocotb.test()
async def core_mini_axi_burst_types_test(dut):
  core_mini_axi = CoreMiniAxiInterface(dut)
  await core_mini_axi.init()
  await core_mini_axi.reset()
  cocotb.start_soon(core_mini_axi.clock.start())

  # AxiBurst.FIXED
  for _ in tqdm.trange(1000):
    beats = random.randint(2, 255)
    wdata = np.random.randint(0, 255, 16 * beats, dtype=np.uint8)
    await core_mini_axi.write(0, wdata, burst=AxiBurst.FIXED)
    rdata = await core_mini_axi.read(0, 16, burst=AxiBurst.FIXED)
    assert (wdata[((beats - 1) * 16):(beats * 16)] == rdata).all()

  # AxiBurst.INCR
  for _ in tqdm.trange(1000):
    beats = random.randint(2, 255)
    wdata = np.random.randint(0, 255, 16 * beats, dtype=np.uint8)
    await core_mini_axi.write(0, wdata, burst=AxiBurst.INCR)
    rdata = await core_mini_axi.read(0, beats * 16, burst=AxiBurst.INCR)
    assert (wdata == rdata).all()

  # AxiBurst.WRAP
  for _ in tqdm.trange(1000):
    beats = random.randint(2, 255)
    wdata = np.random.randint(0, 255, 16 * beats, dtype=np.uint8)
    write_offset = random.randint(1, 15)
    read_offset = random.randint(1, 15)
    await core_mini_axi.write(write_offset, wdata, burst=AxiBurst.WRAP)
    rdata = await core_mini_axi.read(read_offset, 16, burst=AxiBurst.WRAP)
    expected = np.concatenate([wdata[-write_offset:], wdata[-16:-write_offset]])
    assert (expected == np.roll(rdata, read_offset)).all()

@cocotb.test()
async def core_mini_axi_float_csr_test(dut):
  core_mini_axi = CoreMiniAxiInterface(dut)
  await core_mini_axi.init()
  await core_mini_axi.reset()
  cocotb.start_soon(core_mini_axi.clock.start())
  r = runfiles.Create()

  with open(r.Rlocation("coralnpu_hw/tests/cocotb/float_csr_interlock_test.elf"), "rb") as f:
    entry_point = await core_mini_axi.load_elf(f)
    await core_mini_axi.execute_from(entry_point)

    await core_mini_axi.wait_for_halted()
    assert core_mini_axi.dut.io_fault.value == 0

@cocotb.test()
async def unreachable_prefetch_fault(dut):
  fixture = await Fixture.Create(dut)
  r = runfiles.Create()
  cases = [
    ('mpause', 0),
    ('jalr', 0),
    ('branch_forward', 0),
    ('branch_backward', 0),
    ('ebreak', 0),
    ('ecall', 1),
    # ('vill1', 1),
    ('vill2', 1),
    ('unimp', 1),
    ('load', 1),
    ('store', 1),
    ('csrr', 1),
    ('csrw', 1),
  ]
  await fixture.load_elf_and_lookup_symbols(
      r.Rlocation('coralnpu_hw/tests/cocotb/unreachable_prefetch_fault.elf'),
      ['impl', 'iaf_count', 'other_count'] + [c for c, _ in cases] + ['wfi'],
  )

  for c, expected_exceptions in tqdm.tqdm(cases):
    await fixture.write_ptr('impl', c)
    await fixture.run_to_halt()
    iaf_count = (await fixture.read_word('iaf_count')).view(np.int32)[0]
    other_count = (await fixture.read_word('other_count')).view(np.uint32)[0]
    assert iaf_count == 0
    assert other_count == expected_exceptions

  for c in tqdm.tqdm(['wfi']):
    await fixture.write_ptr('impl', c)
    await fixture.core_mini_axi.execute_from(fixture.entry_point)
    await fixture.core_mini_axi.wait_for_wfi()
    iaf_count = (await fixture.read_word('iaf_count')).view(np.int32)[0]
    other_count = (await fixture.read_word('other_count')).view(np.uint32)[0]
    assert iaf_count == 0
    assert other_count == 0

@cocotb.test()
async def core_mini_axi_frm_test(dut):
  """Tests the FRM CSR with valid and invalid values."""
  fixture = await Fixture.Create(dut)
  r = runfiles.Create()

  await fixture.load_elf_and_lookup_symbols(
      r.Rlocation("coralnpu_hw/tests/cocotb/frm_test.elf"),
      ['frm', 'result', 'faulted', 'mcause', 'mtval'],
  )

  for mode in range(8):
    await fixture.write('frm', np.array([mode], dtype=np.uint32))
    valid_mode = (mode <= 4)
    await fixture.run_to_halt()
    faulted = (await fixture.read('faulted', 4)).view(np.uint32)
    mcause = (await fixture.read('mcause', 4)).view(np.uint32)
    if valid_mode:
      assert faulted == 0
    else:
      assert(mcause == 0x2)

@cocotb.test()
async def core_mini_axi_backdoor_load_test(dut):
  """Compares front-door AXI load vs backdoor load for the same ELF."""
  core_mini_axi = CoreMiniAxiInterface(dut)
  await core_mini_axi.init()
  await core_mini_axi.reset()
  cocotb.start_soon(core_mini_axi.clock.start())
  r = runfiles.Create()

  elf_path = r.Rlocation("coralnpu_hw/tests/cocotb/math.elf")

  # 1. Load via AXI (front-door) and capture memory state
  await core_mini_axi.reset()
  await ClockCycles(dut.io_aclk, 10)
  # Zero out memory first
  await core_mini_axi.write(0x0, np.zeros(0x2000, dtype=np.uint8))
  await core_mini_axi.write(0x10000, np.zeros(0x8000, dtype=np.uint8))

  with open(elf_path, "rb") as f:
    await core_mini_axi.load_elf_axi(f)
    # We'll read back ITCM (0x0-0x2000) and DTCM (0x10000-0x18000)
    itcm_front = await core_mini_axi.read(0x0, 0x2000)
    dtcm_front = await core_mini_axi.read(0x10000, 0x8000)

  # 2. Reset and load via backdoor
  await core_mini_axi.reset()
  # Wait a few cycles to ensure SRAMs are initialized and registered
  await ClockCycles(dut.io_aclk, 10)

  # Zero out memory first to be sure
  await core_mini_axi.write(0x0, np.zeros(0x2000, dtype=np.uint8))
  await core_mini_axi.write(0x10000, np.zeros(0x8000, dtype=np.uint8))

  with open(elf_path, "rb") as f:
    entry_point = await core_mini_axi.load_elf_backdoor(f)
    itcm_back = await core_mini_axi.read(0x0, 0x2000)
    dtcm_back = await core_mini_axi.read(0x10000, 0x8000)

  # 3. Compare
  assert (itcm_front == itcm_back).all(), "ITCM mismatch between AXI and Backdoor load"
  assert (dtcm_front == dtcm_back).all(), "DTCM mismatch between AXI and Backdoor load"

  # 4. Execute to ensure it actually works
  await core_mini_axi.execute_from(entry_point)
  await core_mini_axi.wait_for_halted()
  assert core_mini_axi.dut.io_fault.value == 0
  dut._log.info("Backdoor load comparison test passed!")
