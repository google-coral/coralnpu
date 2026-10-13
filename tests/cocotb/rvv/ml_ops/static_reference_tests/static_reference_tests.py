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

import numpy as np
from coralnpu_test_utils.coralflow.base_fixture import BaseCoralNPUFixture
from coralnpu_test_utils.coralflow.runner import coralflow_main, coralflow_test
from sw.utils.metrics import log_matmul_metrics


@coralflow_test
async def float_matmul_16x48x16_test(fixture: BaseCoralNPUFixture):
    # Frozen dimensions
    LHS_ROWS = 16
    RHS_COLS = 16
    INNER = 48

    await fixture.load_elf_and_lookup_symbols(
        'coralnpu_hw/tests/cocotb/rvv/ml_ops/static_reference_tests/float_matmul_16x48x16.elf',
        ['lhs_input', 'rhs_input', 'result_output', 'csr_cycle_count'],
    )

    # Generate deterministic test data using a fixed seed (ensures power profile consistency)
    rng = np.random.default_rng(seed=42)
    lhs_data = rng.uniform(-5.0, 5.0, [LHS_ROWS, INNER]).astype(np.float32)
    rhs_data = rng.uniform(-5.0, 5.0, [INNER, RHS_COLS]).astype(np.float32)
    expected = np.matmul(lhs_data, rhs_data)

    # Write inputs and run
    await fixture.write('lhs_input', lhs_data.flatten())
    await fixture.write('rhs_input', rhs_data.transpose().flatten())
    await fixture.run_to_halt(timeout_cycles=10_000_000)

    # Verify results
    actual = (await fixture.read('result_output', LHS_ROWS * RHS_COLS *
                                 4)).view(dtype=np.float32
                                          ).reshape([LHS_ROWS, RHS_COLS])
    np.testing.assert_allclose(expected, actual, rtol=1e-4, atol=1e-4)

    # Log metrics for power/perf analysis
    csr_cycle_count = await fixture.read_word('csr_cycle_count')
    log_matmul_metrics(
        fixture, "float_matmul_16x48x16", csr_cycle_count, LHS_ROWS, RHS_COLS,
        INNER
    )


@coralflow_test
async def int_matmul_16x48x16_test(fixture: BaseCoralNPUFixture):
    # Frozen dimensions
    LHS_ROWS = 16
    RHS_COLS = 16
    INNER = 48

    await fixture.load_elf_and_lookup_symbols(
        'coralnpu_hw/tests/cocotb/rvv/ml_ops/static_reference_tests/int_matmul_16x48x16.elf',
        ['lhs_input', 'rhs_input', 'result_output', 'csr_cycle_count'],
    )

    # Generate deterministic test data using a fixed seed (ensures power profile consistency)
    rng = np.random.default_rng(seed=42)
    lhs_data = rng.integers(-128, 128, [LHS_ROWS, INNER], dtype=np.int8)
    rhs_data = rng.integers(-128, 128, [INNER, RHS_COLS], dtype=np.int8)
    expected = np.matmul(lhs_data.astype(np.int32), rhs_data.astype(np.int32))

    # Write inputs and run
    await fixture.write('lhs_input', lhs_data.flatten())
    await fixture.write('rhs_input', rhs_data.transpose().flatten())
    await fixture.run_to_halt(timeout_cycles=10_000_000)

    # Verify results
    actual = (await fixture.read('result_output', LHS_ROWS * RHS_COLS *
                                 4)).view(dtype=np.int32
                                          ).reshape([LHS_ROWS, RHS_COLS])
    assert ((expected == actual).all())

    # Log metrics for power/perf analysis
    csr_cycle_count = await fixture.read_word('csr_cycle_count')
    log_matmul_metrics(
        fixture, "int_matmul_16x48x16", csr_cycle_count, LHS_ROWS, RHS_COLS,
        INNER
    )


if __name__ == '__main__':
    coralflow_main()
