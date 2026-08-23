# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

import cocotb
from coralnpu_test_utils.sim_test_fixture import Fixture
from bazel_tools.tools.python.runfiles import runfiles


@cocotb.test()
async def rvv_fflags_test(dut):
    """Test that RVV floating point operations correctly update fflags."""
    fixture = await Fixture.Create(dut)
    r = runfiles.Create()
    elf_file = 'rvv_fflags_test.elf'

    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation('coralnpu_hw/tests/cocotb/' + elf_file), [
            'fflags_initial',
            'fflags_divzero',
            'fcsr_divzero',
            'fflags_invalid',
            'fflags_overflow',
            'fflags_underflow',
            'fnmsub_result',
            'rmm_fadd_result',
            'rmm_fflags',
            'fflags_cleared',
            'fflags_hazard',
        ]
    )

    cycles = await fixture.run_to_halt(timeout_cycles=1000000)
    dut._log.info(f"Cycle count: {cycles}")

    async def read_u32(symbol_name):
        addr = fixture.symbols[symbol_name]
        actual_bytes = await fixture.core_mini_axi.read(addr, 4)
        return int.from_bytes(actual_bytes.tobytes(), 'little')

    fflags_initial = await read_u32('fflags_initial')
    fflags_divzero = await read_u32('fflags_divzero')
    fcsr_divzero = await read_u32('fcsr_divzero')
    fflags_invalid = await read_u32('fflags_invalid')
    fflags_overflow = await read_u32('fflags_overflow')
    fflags_underflow = await read_u32('fflags_underflow')
    fnmsub_result = await read_u32('fnmsub_result')
    rmm_fadd_result = await read_u32('rmm_fadd_result')
    rmm_fflags = await read_u32('rmm_fflags')
    fflags_cleared = await read_u32('fflags_cleared')

    dut._log.info(f"fflags_initial: {hex(fflags_initial)}")
    dut._log.info(
        f"fflags_divzero: {hex(fflags_divzero)} (fcsr: {hex(fcsr_divzero)})"
    )
    dut._log.info(f"fflags_invalid: {hex(fflags_invalid)}")
    dut._log.info(f"fflags_overflow: {hex(fflags_overflow)}")
    dut._log.info(
        f"fflags_underflow: {hex(fflags_underflow)}, fnmsub_result: {hex(fnmsub_result)}"
    )
    dut._log.info(
        f"rmm_fadd_result: {hex(rmm_fadd_result)}, rmm_fflags: {hex(rmm_fflags)}"
    )
    dut._log.info(f"fflags_cleared: {hex(fflags_cleared)}")

    # Check initial fflags is 0
    assert fflags_initial == 0x0, f"Expected fflags_initial=0x0, got {hex(fflags_initial)}"

    # Check divide by zero sets DZ bit (0x8)
    assert fflags_divzero == 0x8, f"Expected fflags_divzero=0x8 (DZ), got {hex(fflags_divzero)}"
    assert (
        fcsr_divzero & 0x1F
    ) == 0x8, f"Expected fcsr[4:0]=0x8 (DZ), got {hex(fcsr_divzero)}"

    # Check invalid op sets NV bit (0x10)
    assert fflags_invalid == 0x10, f"Expected fflags_invalid=0x10 (NV), got {hex(fflags_invalid)}"

    # Check overflow sets OF (0x4) | NX (0x1) = 0x5
    assert fflags_overflow == 0x5, f"Expected fflags_overflow=0x5 (OF|NX), got {hex(fflags_overflow)}"

    # Check underflow sets UF (0x2) | NX (0x1) = 0x3 and result is 0x11
    assert fnmsub_result == 0x11, f"Expected fnmsub_result=0x11, got {hex(fnmsub_result)}"
    assert fflags_underflow == 0x3, f"Expected fflags_underflow=0x3 (UF|NX), got {hex(fflags_underflow)}"

    # Check RMM tie rounding away from zero (0x3f800001) and NX flag (0x1)
    assert rmm_fadd_result == 0x3F800001, f"Expected rmm_fadd_result=0x3f800001 (RMM tie away from zero), got {hex(rmm_fadd_result)}"
    assert rmm_fflags == 0x1, f"Expected rmm_fflags=0x1 (NX), got {hex(rmm_fflags)}"

    # Check cleared fflags is 0
    assert fflags_cleared == 0x0, f"Expected fflags_cleared=0x0, got {hex(fflags_cleared)}"

    # Check concurrent CSR write and vector exception hazard cases
    hazard_addr = fixture.symbols['fflags_hazard']
    hazard_bytes = await fixture.core_mini_axi.read(hazard_addr, 16 * 4)
    for i in range(16):
        val = int.from_bytes(
            hazard_bytes[i * 4:(i + 1) * 4].tobytes(), 'little'
        )
        dut._log.info(f"fflags_hazard[{i}]: {hex(val)}")
        # The CSR write of 0x02 (UF) occurs later in program order than vfdiv.vv (NX=0x01).
        # Therefore, the final value must be exactly 0x02 (UF), overwriting the initial 0x10 (NV)
        # and NOT retaining or OR'ing in the earlier vfdiv's 0x01 (NX).
        assert val == 0x02, (
            f"Hazard test delay {i}: expected exact fflags=0x02 (UF), got {hex(val)}"
        )

    dut._log.info("All RVV fflags exception tests passed!")
