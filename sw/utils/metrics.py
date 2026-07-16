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


def log_matmul_metrics(
    dut,
    test_name: str,
    cycles: int,
    lhs_rows: int = 0,
    rhs_cols: int = 0,
    inner: int = 0,
    *,
    macs: int | None = None,
    num_heads: int = 1,
    batch_size: int = 1,
):
    """Logs performance metrics for matrix multiplication and GEMM workloads.

    Calculates total MACs as (num_heads * batch_size * lhs_rows * rhs_cols * inner)
    unless explicitly overridden via `macs=...`.
    """
    if macs is not None:
        total_macs = macs
    else:
        total_macs = num_heads * batch_size * lhs_rows * rhs_cols * inner

    cycles_per_mac = cycles / total_macs if total_macs > 0 else 0.0
    banner = (
        f"\n{'='*60}\n PERFORMANCE METRICS: {test_name}\n{'-'*60}\n"
        f"  Total Cycles   : {cycles:,}\n  Total MACs     : {total_macs:,}\n"
        f"  Cycles / MAC   : {cycles_per_mac:.2f}\n{'='*60}"
    )
    dut._log.info(banner)


def log_vector_metrics(dut, test_name: str, cycles: int, total_elements: int):
    cycles_per_element = cycles / total_elements if total_elements > 0 else 0.0
    banner = (
        f"\n{'='*60}\n PERFORMANCE METRICS: {test_name}\n{'-'*60}\n"
        f"  Total Cycles     : {cycles:,}\n  Total Elements   : {total_elements:,}\n"
        f"  Cycles / Element : {cycles_per_element:.3f}\n{'='*60}"
    )
    dut._log.info(banner)
