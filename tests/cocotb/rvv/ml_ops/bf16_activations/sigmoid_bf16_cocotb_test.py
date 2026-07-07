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

import os
import cocotb
import ml_dtypes
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.sim_test_fixture import Fixture

# 512KB memory map shifts CSRs to 0x200000
CSR_BASE = 0x200000
ELF = "coralnpu_hw/tests/cocotb/rvv/ml_ops/bf16_activations/sigmoid_bf16_test.elf"
CANARY = np.uint16(0xBEEF)
MAX_ULPS = 3
VARIANTS = [(0, "vfrdiv"), (1, "vfrec7 NR"), (2, "vfrec7 raw")]


def f32_to_bf16(x):
    """float32 array -> raw bf16 bit patterns (uint16), round-to-nearest-even"""
    return np.asarray(
        x, dtype=np.float32
    ).astype(ml_dtypes.bfloat16).view(np.uint16)


def bf16_to_fp32(b):
    """raw bf16 bit patterns (uint16) -> float32 array"""
    return np.asarray(
        b, dtype=np.uint16
    ).view(ml_dtypes.bfloat16).astype(np.float32)


def check(dev, golden, label, max_ulps=MAX_ULPS, atol=1e-37):
    golden = np.asarray(golden, dtype=np.float64)
    ulp = np.abs(
        dev.astype(np.int32) -
        f32_to_bf16(golden.astype(np.float32)).astype(np.int32)
    )
    abs_err = np.abs(bf16_to_fp32(dev).astype(np.float64) - golden)
    over = (ulp > max_ulps) & (abs_err > atol)
    if over.any():
        w = int(np.argmax(np.where(over, ulp, -1)))
        raise AssertionError(
            f"{label}: {int(ulp[over].max())} ULP > {max_ulps} "
            f"(dev={float(bf16_to_fp32(dev)[w]):.3e} golden={float(golden[w]):.3e})"
        )
    keep = ~((ulp > max_ulps) & (abs_err <= atol))
    return int(ulp[keep].max()) if keep.any() else 0


async def run(fixture, x, kernel_id=0, alias=0, repeat=1):
    n = x.shape[0]
    pad = 8
    await fixture.write("active_n", np.array([n], dtype=np.uint32))
    await fixture.write("kernel_id", np.array([kernel_id], dtype=np.uint32))
    await fixture.write("alias", np.array([alias], dtype=np.uint32))
    await fixture.write("repeat", np.array([repeat], dtype=np.uint32))
    await fixture.write("sigmoid_in", f32_to_bf16(x))
    await fixture.write(
        "sigmoid_out", np.full(n + pad, CANARY, dtype=np.uint16)
    )

    sim_cycles = await fixture.run_to_halt(timeout_cycles=10_000_000)
    out = (await fixture.read("sigmoid_out", (n + pad) * 2)).view(np.uint16)
    if repeat >= 1:
        np.testing.assert_array_equal(out[n:], np.full(pad, CANARY, np.uint16))
    # cyc = int((await fixture.read("cycle_count", 4)).view(np.float32)[0])
    xq = bf16_to_fp32(f32_to_bf16(x)).astype(np.float64)
    golden = 1.0 / (1.0 + np.exp(-xq))
    # golden = 1.0 / (1.0 + np.exp(-x.astype(np.float64)))
    return out[:n], golden, sim_cycles


async def _setup(dut):
    r = runfiles.Create()
    fixture = await Fixture.Create(dut, csr_base_addr=CSR_BASE)
    elf_path = r.Rlocation(ELF)
    if not elf_path or not os.path.exists(elf_path):
        raise FileNotFoundError(f"Could not find ELF at {elf_path}")
    await fixture.load_elf_and_lookup_symbols(
        elf_path,
        [
            "sigmoid_in",
            "sigmoid_out",
            "active_n",
            "kernel_id",
            "alias",
            "repeat",
            "cycle_count",
        ],
    )
    await fixture.core_mini_axi.reset()
    return fixture


@cocotb.test()
async def sigmoid_bf16_corr_test(dut):
    fixture = await _setup(dut)
    rng = np.random.default_rng(seed=7)
    log = dut._log

    outs = {}
    for kid, name in VARIANTS:
        worst = 0
        x = np.linspace(-15.0, 15.0, 512).astype(np.float32)
        x[:8] = [88.0, -88.0, 90.0, -90.0, 40.0, -40.0, 0.0, -0.0]
        out, golden, _ = await run(fixture, x, kid)
        outs[kid] = out
        worst = max(worst, check(out, golden, "sweep"))
        for n in [1, 31, 33, 640, 643]:
            out, golden, _ = await run(
                fixture,
                rng.uniform(-10.0, 10.0, n).astype(np.float32), kid
            )
            worst = max(worst, check(out, golden, "sweep"))
        out, golden, _ = await run(
            fixture,
            rng.uniform(-10.0, 10.0, n).astype(np.float32),
            kid,
            alias=1
        )
        worst = max(worst, check(out, golden, "in-place"))
        log.info(f"sigmoid [{name}]: worst {worst} ULP (limit {MAX_ULPS})")

    for kid in (1, 2):
        diff = np.abs(outs[0].astype(np.int32) - outs[kid].astype(np.int32))
        name = dict(VARIANTS)[kid]
        log.info(
            f"  vfrdiv vs {name}: {(diff == 0).mean() * 100:.1f}% bit-identical, "
            f"max {int(diff.max())} ULP apart"
        )


@cocotb.test()
async def sigmoid_bf16_perf_test(dut):
    fixture = await _setup(dut)
    rng = np.random.default_rng(seed=7)
    log = dut._log

    nbig = 4096
    xb = rng.uniform(-12.0, 12.0, nbig).astype(np.float32)
    _, _, startup = await run(fixture, xb, 0, repeat=0)
    log.info(f"fixed startup (repeat=0): {startup} cyc")
    base = None
    for kid, name in VARIANTS:
        out, golden, cyc = await run(fixture, xb, kid)
        w = check(out, golden, name)
        pc = cyc - startup
        base = base or pc
        log.info(
            f"  {name:11s}: raw {cyc} cyc | per-call {pc} cyc "
            f"({pc / nbig:.2f} cyc/elem, {base / pc:.3f}x, worst {w} ULP"
        )
