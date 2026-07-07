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

CSR_BASE = 0x200000
ELF = "coralnpu_hw/tests/cocotb/rvv/ml_ops/bf16_activations/rvv_math_test.elf"
HALF_ULP = 2.0**-8  # bf16 half-ULP relative spacing (ship line)

# bf16 patterns for the widen check: signed zeros, +-1, +-2, +-inf, q/sNaN, and
# the smallest/largest sub/normal magnitudes.
BF16_SPECIALS = np.array(
    [
        0x0000,
        0x8000,
        0x3F80,
        0xBF80,
        0x4000,
        0x7F80,
        0xFF80,
        0x7FC0,
        0xFFC0,
        0x7F81,
        0x0001,
        0x8001,
        0x007F,
        0x0080,
        0x7F7F,
        0xFF7F,
    ],
    dtype=np.uint16,
)


def f32_to_bf16(x):
    u = np.ascontiguousarray(x, dtype=np.float32).view(np.uint32)
    lsb = (u >> np.uint32(16)) & np.uint32(1)
    return ((u + np.uint32(0x7FFF) + lsb) >> np.uint32(16)).astype(np.uint16)


def bf16_to_fp32(b):
    return (b.astype(np.uint32) << np.uint32(16)).view(np.float32)


# bf16 patterns for the integer-key max: signed zeros, +-inf, +-2, +-1. NaN is
# excluded by contract (it keys above +inf, which the kernels never see).
MAXKEY_SPECIALS = np.array(
    [0x0000, 0x8000, 0x7F80, 0xFF80, 0x4000, 0xC000, 0x3F80, 0xBF80], dtype=np.uint16
)


def make_narrow_inputs(rng, n):
    # Random fp32 plus exact half-way ties (low 16 bits = 0x8000, keep-bit varying)
    # so round-to-nearest-even must break both ways. Magnitudes stay moderate so
    # `bits + 0x7fff` never overflows uint32 in device or reference.
    x = rng.uniform(-1000.0, 1000.0, n).astype(np.float32)
    u = x.view(np.uint32).copy()
    k = max(1, n // 3)
    u[:k] = (u[:k] & np.uint32(0xFFFF0000)) | np.uint32(0x8000)  # tie, keep-bit varies
    u[k : 2 * k] = (u[k : 2 * k] & np.uint32(0xFFFE0000)) | np.uint32(
        0x8000
    )  # tie, keep-bit even
    return u.view(np.float32)


@cocotb.test()
async def rvv_math_test(dut):
    log = dut._log
    r = runfiles.Create()
    fixture = await Fixture.Create(dut, csr_base_addr=CSR_BASE)
    elf = r.Rlocation(ELF)
    if not elf or not os.path.exists(elf):
        raise FileNotFoundError(f"ELF not found at {elf}")
    await fixture.load_elf_and_lookup_symbols(
        elf,
        [
            "cvt_in",
            "cvt_out",
            "narrow_in",
            "narrow_out",
            "exp_in",
            "exp_out",
            "exp_neg_out",
            "expnp_in",
            "expnp_out",
            "scalar_exp_out",
            "recip_in",
            "recip_out",
            "recip_raw_out",
            "widen_in",
            "widen_out",
            "exp_neg_fma_out",
            "maxkey_in",
            "maxkey_out",
            "treesum_in",
            "treesum_out",
            "active_n",
            "cycle_count",
        ],
    )
    await fixture.core_mini_axi.reset()
    rng = np.random.default_rng(42)

    for n in [1, 31, 33, 256, 643, 4096]:  # includes non-multiples of the 32-lane group
        cvt = f32_to_bf16(rng.uniform(-10.0, 10.0, n).astype(np.float32))
        narrow_in = make_narrow_inputs(rng, n)
        exp_in = rng.uniform(-80.0, 80.0, n).astype(np.float32)
        exp_in[: min(7, n)] = np.array(
            [-100, -88, -87.9, 0, 87.9, 88, 100], np.float32
        )[: min(7, n)]
        expnp_in = -np.abs(exp_in).astype(np.float32)  # nonpos form needs x <= 0
        expnp_in[: min(4, n)] = np.array([0, -0.0, -88, -100], np.float32)[: min(4, n)]
        recip_in = np.exp(rng.uniform(np.log(1e-3), np.log(1e3), n)).astype(np.float32)
        recip_in[: min(8, n)] = np.array(
            [1.0, 1.0000061, 2.0, 0.5, 1e-3, 1e3, 1e-6, 1e6], np.float32
        )[: min(8, n)]
        widen_in = rng.integers(0, 1 << 16, n, dtype=np.uint16)
        widen_in[: min(BF16_SPECIALS.size, n)] = BF16_SPECIALS[
            : min(BF16_SPECIALS.size, n)
        ]
        # integer-key max: finite bf16 (from fp32, never NaN) plus signed-zero /
        # +-inf specials so the key ordering and +0 > -0 tie-break are exercised.
        maxkey_in = f32_to_bf16(rng.uniform(-100.0, 100.0, n).astype(np.float32))
        maxkey_in[: min(MAXKEY_SPECIALS.size, n)] = MAXKEY_SPECIALS[
            : min(MAXKEY_SPECIALS.size, n)
        ]
        # tree-fold sum: positive, moderate range (mirrors summing exp outputs).
        treesum_in = rng.uniform(1e-3, 2.0, n).astype(np.float32)

        await fixture.write("active_n", np.array([n], np.uint32))
        for name, val in [
            ("cvt_in", cvt),
            ("narrow_in", narrow_in),
            ("exp_in", exp_in),
            ("expnp_in", expnp_in),
            ("recip_in", recip_in),
            ("widen_in", widen_in),
            ("maxkey_in", maxkey_in),
            ("treesum_in", treesum_in),
        ]:
            await fixture.write(name, val)
        for name, dt in [
            ("cvt_out", np.uint16),
            ("narrow_out", np.uint16),
            ("exp_out", np.float32),
            ("exp_neg_out", np.float32),
            ("expnp_out", np.float32),
            ("scalar_exp_out", np.float32),
            ("recip_out", np.float32),
            ("recip_raw_out", np.float32),
            ("widen_out", np.float32),
            ("exp_neg_fma_out", np.float32),
            ("maxkey_out", np.float32),
            ("treesum_out", np.float32),
        ]:
            await fixture.write(name, np.zeros(n, dt))
        await fixture.run_to_halt(timeout_cycles=10_000_000)

        # (1) round-trip is the identity for bf16 values; (2) RNE narrow is bit-exact.
        np.testing.assert_array_equal(
            (await fixture.read("cvt_out", n * 2)).view(np.uint16), cvt
        )
        np.testing.assert_array_equal(
            (await fixture.read("narrow_out", n * 2)).view(np.uint16),
            f32_to_bf16(narrow_in),
        )

        # (3) exp: all three vector entries + scalar mirror vs clamped exact exp.
        # The kernel clamps to [-88, 88]; the atol floor lets the flushed tail
        # (golden ~1e-39 -> 0 on device) compare equal so rtol applies where the
        # result is non-negligible.
        gp = np.exp(np.clip(exp_in, -88, 88).astype(np.float64))
        gn = np.exp(-np.clip(exp_in, -88, 88).astype(np.float64))
        gnp = np.exp(np.clip(expnp_in, -88, 88).astype(np.float64))
        eo = (await fixture.read("exp_out", n * 4)).view(np.float32)
        en = (await fixture.read("exp_neg_out", n * 4)).view(np.float32)
        enp = (await fixture.read("expnp_out", n * 4)).view(np.float32)
        es = (await fixture.read("scalar_exp_out", n * 4)).view(np.float32)
        np.testing.assert_allclose(eo, gp, rtol=3.5e-3, atol=1e-30)
        np.testing.assert_allclose(en, gn, rtol=3.5e-3, atol=1e-30)
        np.testing.assert_allclose(enp, gnp, rtol=3.5e-3, atol=1e-30)
        np.testing.assert_allclose(es, gnp, rtol=3.5e-3, atol=1e-30)  # scalar vs exact
        np.testing.assert_allclose(
            es, enp, rtol=1e-3, atol=1e-30
        )  # scalar tracks vector
        # FMA-core exp(-x): meets the same ship criterion AND is BIT-IDENTICAL to
        # the split-Horner exp_neg at bf16 output (the property the sigmoid kernels
        # rely on -- the fused single-rounding differs only below bf16 resolution).
        efma = (await fixture.read("exp_neg_fma_out", n * 4)).view(np.float32)
        np.testing.assert_allclose(efma, gn, rtol=3.5e-3, atol=1e-30)
        np.testing.assert_array_equal(f32_to_bf16(efma), f32_to_bf16(en))
        # Ship criterion on the dense large-n rows: rel err < bf16 half-ULP.
        if n >= 256:

            def rel(o, g):
                m = g > 1e-30
                return float(np.max(np.abs(o[m] - g[m]) / g[m]))

            rw = max(rel(eo, gp), rel(en, gn), rel(enp, gnp))
            assert (
                rw < HALF_ULP
            ), f"exp rel {rw:.2e} >= {HALF_ULP:.1e}"
            log.info(
                f"exp rel err (n={n}): {rw:.2e} < {2.0 ** -9:.1e} "
                f"(bar: {HALF_ULP:.1e})"
            )

        # (4) reciprocal: refined (vfrec7 + 1 Newton ~2^-14; rtol 2e-4 fails loudly
        # if the Newton step is dropped) and raw (vfrec7 alone, bounded at 2^-7 by
        # the RVV spec; rtol 1.2e-2 gives ~50% margin over that bound). The raw path
        # is what sigmoid kernel_id 2 uses.
        recip_g = 1.0 / recip_in.astype(np.float64)
        ro = (await fixture.read("recip_out", n * 4)).view(np.float32)
        rr = (await fixture.read("recip_raw_out", n * 4)).view(np.float32)
        np.testing.assert_allclose(ro, recip_g, rtol=2e-4, atol=1e-30)
        np.testing.assert_allclose(rr, recip_g, rtol=1.2e-2, atol=1e-30)

        # (4b) integer sign-magnitude-key max == exact bf16 max of the array. The
        # key reorders bits so unsigned-int order matches float order (verified
        # exhaustively in the header note); compare values so +0 == -0 is fine.
        mk = float((await fixture.read("maxkey_out", 4)).view(np.float32)[0])
        assert mk == float(
            bf16_to_fp32(maxkey_in).max()
        ), f"key-max {mk} != exact bf16 max at n={n}"

        # (4c) tree-fold sum vs exact (fp64) sum. The fold changes summation order
        # so compare with a tolerance covering fp32 accumulation over up to 4096
        # well-conditioned positive terms.
        ts = float((await fixture.read("treesum_out", 4)).view(np.float32)[0])
        np.testing.assert_allclose(ts, treesum_in.astype(np.float64).sum(), rtol=5e-5)

        # (5) widen bf16 -> fp32: bit-exact for every non-NaN class (compare raw u32
        # so signed zeros / subnormals count). NaN bits are not portable across the
        # native vs integer widen paths, so a NaN input need only stay some NaN.
        wb = (await fixture.read("widen_out", n * 4)).view(np.uint32)
        wg = widen_in.astype(np.uint32) << np.uint32(16)
        is_nan = ((widen_in & 0x7F80) == 0x7F80) & ((widen_in & 0x007F) != 0)
        np.testing.assert_array_equal(wb[~is_nan], wg[~is_nan])
        no = wb[is_nan]
        assert np.all(
            (((no >> np.uint32(23)) & np.uint32(0xFF)) == 0xFF)
            & ((no & np.uint32(0x7FFFFF)) != 0)
        ), "widened NaN did not stay NaN"
