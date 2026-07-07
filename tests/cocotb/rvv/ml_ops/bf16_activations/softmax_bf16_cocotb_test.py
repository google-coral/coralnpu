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
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles

from coralnpu_test_utils.sim_test_fixture import Fixture

# 512KB memory map shifts CSRs to 0x200000
CSR_BASE = 0x200000
ELF = "coralnpu_hw/tests/cocotb/rvv/ml_ops/bf16_activations/softmax_bf16_test.elf"
CANARY = np.uint16(0xBEEF)
MAX_ULPS = 4
VARIANTS = [(0, "3-pass"), (1, "online")]
SMALL_ROW_KID = 2
SCRATCH_KID = [0]


def f32_to_bf16(x):
    """float32 array -> raw bf16 bit patterns (uint16), round-to-nearest-even"""
    u = np.ascontiguousarray(x, dtype=np.float32).view(np.uint32)
    lsb = (u >> np.uint32(16)) & np.uint32(1)
    return ((u + np.uint32(0x7FFF) + lsb) >> np.uint32(16)).astype(np.uint16)


def bf16_to_fp32(b):
    return (b.astype(np.uint32) << np.uint32(16)).view(np.float32)


def check(dev, golden, label, max_ulps=MAX_ULPS, atol=1e-37):
    golden = np.asarray(golden, dtype=np.float64)
    ulp = np.abs(
        dev.astype(np.int32) - f32_to_bf16(golden.astype(np.float32)).astype(np.int32)
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


def softmax_ref(x):
    xq = bf16_to_fp32(f32_to_bf16(x))
    e = np.exp((xq - xq.max()).astype(np.float64))
    return e / e.sum()


async def run(fixture, x, kernel_id=0, alias=0, scratch_len=None, repeat=1):
    n = x.shape[0]
    pad = 8
    if scratch_len is None:
        scratch_len = n
    await fixture.write("active_n", np.array([n], dtype=np.uint32))
    await fixture.write("active_scratch_len", np.array([scratch_len], dtype=np.uint32))
    await fixture.write("kernel_id", np.array([kernel_id], dtype=np.uint32))
    await fixture.write("alias", np.array([alias], dtype=np.uint32))
    await fixture.write("repeat", np.array([repeat], dtype=np.uint32))
    await fixture.write("softmax_in", f32_to_bf16(x))
    await fixture.write("softmax_out", np.full(n + pad, CANARY, dtype=np.uint16))
    sim_cycles = await fixture.run_to_halt(timeout_cycles=10_000_000)
    ok = int((await fixture.read("softmax_ok", 4)).view(np.uint32)[0])
    out = (await fixture.read("softmax_out", (n + pad) * 2)).view(np.uint16)
    if repeat >= 1:
        np.testing.assert_array_equal(out[n:], np.full(pad, CANARY, np.uint16))
    return ok, out[:n], softmax_ref(x), sim_cycles


async def _setup(dut):
    r = runfiles.Create()
    fixture = await Fixture.Create(dut, csr_base_addr=CSR_BASE)
    elf_path = r.Rlocation(ELF)
    if not elf_path or not os.path.exists(elf_path):
        raise FileNotFoundError(f"Cound not find ELF at {elf_path}")
    await fixture.load_elf_and_lookup_symbols(
        elf_path,
        [
            "softmax_in",
            "softmax_out",
            "active_n",
            "active_scratch_len",
            "kernel_id",
            "alias",
            "repeat",
            "softmax_ok",
            "cycle_count",
        ],
    )
    await fixture.core_mini_axi.reset()
    return fixture


@cocotb.test()
async def softmax_bf16_corr_test(dut):
    fixture = await _setup(dut)
    rng = np.random.default_rng(seed=13)
    log = dut._log

    n = 256
    for kid, name in VARIANTS:
        worst = 0
        cases = {
            "all-equal": np.zeros(n, np.float32),
            "one-hot": np.concatenate(([30.0], np.zeros(n - 1))).astype(np.float32),
            "large-mag": rng.uniform(-50.0, 50.0, n).astype(np.float32),
            "random": rng.uniform(-10.0, 10.0, n).astype(np.float32),
            "ascending": np.linspace(-10.0, 10.0, n).astype(np.float32),
        }
        for cname, x in cases.items():
            ok, out, golden, _ = await run(fixture, x, kid)
            assert ok == 1, name
            worst = max(worst, check(out, golden, cname))
        for m in [1, 31, 33, 640, 643, 2048]:
            x = rng.uniform(-10.0, 10.0, m).astype(np.float32)
            ok, out, golden, _ = await run(fixture, x, kid)
            assert ok == 1
            worst = max(worst, check(out, golden, f"n={m}"))
        x = rng.uniform(-10.0, 10.0, n).astype(np.float32)
        ok, out, golden, _ = await run(fixture, x, kid, alias=1)
        assert ok == 1
        worst = max(worst, check(out, golden, "in-place"))
        xasc = np.linspace(-10.0, 10.0, 2048).astype(np.float32)
        ok, out, golden, _ = await run(fixture, xasc, kid)
        assert ok == 1
        worst = max(worst, check(out, golden, "asc-2048"))
        log.info(f"softmax [{name}]: worst {worst} ULP (limit {MAX_ULPS})")

    worst = 0
    for m in [1, 2, 8, 16, 31, 32]:
        for x in (
            rng.uniform(-30.0, 30.0, m).astype(np.float32),
            np.zeros(m, np.float32),
            (
                np.concatenate(([40.0], np.zeros(m - 1))).astype(np.float32)
                if m > 1
                else np.array([3.0], np.float32)
            ),
        ):
            ok_s, out_s, golden, _ = await run(fixture, x, SMALL_ROW_KID)
            assert ok_s == 1, f"small-row refused n={m}"
            ok_b, out_b, _, _ = await run(fixture, x, 0)
            np.testing.assert_array_equal(out_s, out_b)
            worst = max(worst, check(out_s, golden, f"small n={m}"))
    log.info(f"sofrmax [small-row]: worst {worst} ULP, bit-identical to 3-pass")

    ok_s, out_s, _, _ = await run(
        fixture, rng.uniform(-10.0, 10.0, n).astype(np.float32), SMALL_ROW_KID
    )
    assert ok_s == 0, "small-row must refuse n > VLMAX"
    np.testing.assert_array_equal(out_s, np.full(n, CANARY, np.uint16))
    ok_s, out_s, golden, _ = await run(
        fixture,
        rng.uniform(-10.0, 10.0, 32).astype(np.float32),
        SMALL_ROW_KID,
        scratch_len=0,
    )
    assert ok_s == 1, "small-row nust run without scratch"
    check(out_s, golden, "small-row zero-sratch")

    for kid in SCRATCH_KID:
        ok, out, _, _ = await run(
            fixture,
            rng.uniform(-10.0, 10.0, n).astype(np.float32),
            0,
            scratch_len=n - 1,
        )
        assert ok == 0, dict(VARIANTS)[kid]
        np.testing.assert_array_equal(out, np.full(n, CANARY, np.uint16))
    xz = rng.uniform(-10.0, 10.0, n).astype(np.float32)
    for kid, name in VARIANTS:
        ok, out, golden, _ = await run(fixture, xz, kid, scratch_len=0)
        if kid in SCRATCH_KID:
            assert ok == 0, name
            np.testing.assert_array_equal(out, np.full(n, CANARY, np.uint16))
        else:
            assert ok == 1, name
            check(out, golden, name)


@cocotb.test()
async def softmax_bf16_perf_test(dut):
    fixture = await _setup(dut)
    rng = np.random.default_rng(seed=13)
    log = dut._log

    nbig = 4096
    xb = rng.uniform(-10.0, 10.0, nbig).astype(np.float32)
    _, _, _, startup = await run(fixture, xb, 0, repeat=0)
    log.info(f"fixed startup (repeat=0): {startup} cyc")
    base = None
    for kid, name in VARIANTS:
        ok, out, golden, cyc = await run(fixture, xb, kid)
        assert ok == 1, name
        w = check(out, golden, name)
        pc = cyc - startup
        base = base or pc
        scratch_b = nbig * 4 if kid in SCRATCH_KID else 0
        log.info(
            f"  n={nbig} {name}: raw {cyc} cyc | per-call {pc} "
            f"({pc / nbig:.2f} cyc/elem, {base / pc:.3f}x, scratch {scratch_b} B, worst {w} ULP)"
        )

    nsr, reps = 32, 64
    xs = rng.uniform(-10.0, 10.0, nsr).astype(np.float32)
    base = None
    for kid, name in VARIANTS + [(SMALL_ROW_KID, "small-row")]:
        ok, out, golden, cyc_raw = await run(fixture, xs, kid)
        assert ok == 1
        w = check(out, golden, name)
        _, _, _, cyc = await run(fixture, xs, kid, repeat=reps)
        pc = (cyc - startup) / reps
        base = base or pc
        log.info(
            f"  n={nsr} {name}: raw {cyc_raw} cyc | per-call {pc:.0f} cyc "
            f"({pc / nsr:.2f} cyc/elem, {base / pc:.3f}x, worst {w} ULP)"
        )
