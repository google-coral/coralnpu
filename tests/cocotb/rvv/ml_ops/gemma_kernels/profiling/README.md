# Gemma RVV Operator Profiling

This directory collects performance data for every executable operator under
`gemma_kernels` and preserves the data source, readout method, and raw logs. It
reports **cycles from actual NPU execution** rather than replacing measurements
with static estimates.

## Coverage

| Operator | Implementation | Main coverage |
| --- | --- | --- |
| RMSNorm | FP32, BF16 | Dynamic sequence length and hidden size |
| Residual Add | FP32, BF16 | Element-wise residual addition |
| Tanh-GELU x Up | FP32, BF16 | Gemma MLP activation and element-wise multiplication |
| MatMul / GeMV | FP32, BF16 | M=1 decode GeMV and 2D prefill MatMul |
| INT8 MatMul / GeMV | INT8 input, INT32 output | K/N tail handling |
| FlashAttention | FP32, BF16 | Prefill, decode, MQA/GQA shapes |
| Gemma Decoder Layer (profiled) | BF16 | End-to-end attention, MLP, RMSNorm, and residual path |

## Cycle data provenance

Every `kernel_cycles` value follows the same runtime path:

1. **The C++ runner writes the value:** for example,
   `rvv_bf16_matmul_runner.cc` calls `mcycle_read()` around the target kernel
   and writes `end - start` to the global `cycle_count`.
2. **The ELF symbol table provides the address:** the Cocotb test calls
   `Fixture.load_elf_and_lookup_symbols()`; the underlying
   `CoreMiniAxiInterface.lookup_symbol()` uses `pyelftools.ELFFile` to walk
   `SHT_SYMTAB` and obtain the `st_value` address of `cycle_count`.
3. **AXI provides the value:** after execution, the test calls
   `fixture.read('cycle_count', 4)` or `fixture.read_word('cycle_count')` and
   reads the 32-bit cycle value from simulated NPU memory.
4. **The log is saved and parsed:** `sw/utils/metrics.py` prints a
   `PERFORMANCE METRICS` block. The profiling script saves the complete
   Bazel/Cocotb log before parsing `Total Cycles`, `Total MACs`, or
   `Total Elements`.

Therefore, `kernel_cycles` means the RISC-V `mcycle` delta inside the measured
kernel call in the runner. It is not Python/host time and does not necessarily
equal the simulated clock count returned by `run_to_halt()`.

`run_to_halt()` measures simulated clocks from the program entry point to
`io_halted`, including startup and exit overhead. Record it explicitly when
comparing the two quantities; the default report prefers the kernel-level
`cycle_count`.

## Usage

Run all operators from the repository root:

```bash
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute
```

Run selected operators:

```bash
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators matmul flashattention gemma_decoder_layer
```

Experimental ELFs or runtime options can be passed to Bazel with
`--test-env KEY=VALUE`. For example, select the software-only BF16 GeMV
pair-load variant:

```bash
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators matmul \
    --test-env BF16_MATMUL_ELF=rvv_bf16_matmul_pair_load.elf \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/pair_load
```

The `vlseg2e16.v` packed-weight experiment sets both the ELF and input-layout
switches:

```bash
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators matmul \
    --test-env BF16_MATMUL_ELF=rvv_bf16_matmul_seg2.elf \
    --test-env BF16_MATMUL_PACKED_B=1 \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/seg2
```

The synthetic Gemma layer can use the same packed-projection schedule:

```bash
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators gemma_decoder_layer \
    --test-env GEMMA_PROFILE_ELF=rvv_bf16_gemma_decoder_layer_profile_seg2.elf \
    --test-env GEMMA_PACKED_PROJECTIONS=1 \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/z19_seg2_decoder
```

The A-cache and block-major variants introduced by `4e376279` use the switches
below. A-cache changes only the location of `A[K]` and does not change the B
layout. The seg2 variants require per-row packed B; block-seg2 variants require
block-major packed B.

```bash
# A-cache with the original row-major B layout.
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators matmul \
    --test-env BF16_MATMUL_ELF=rvv_bf16_matmul_a_cache.elf \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/z19_a_cache_real

# Row-seg2 plus A-cache.
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators matmul \
    --test-env BF16_MATMUL_ELF=rvv_bf16_matmul_seg2_a_cache.elf \
    --test-env BF16_MATMUL_PACKED_B=1 \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/z19_seg2_a_cache

# Block-seg2; both switches are required to avoid the baseline ELF/layout.
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators matmul \
    --test-env BF16_MATMUL_ELF=rvv_bf16_matmul_block_seg2.elf \
    --test-env BF16_MATMUL_BLOCK_PACKED_B=1 \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/z19_block_seg2_validated

# Block-seg2 plus A-cache.
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators matmul \
    --test-env BF16_MATMUL_ELF=rvv_bf16_matmul_block_seg2_a_cache.elf \
    --test-env BF16_MATMUL_BLOCK_PACKED_B=1 \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/z19_block_seg2_a_cache
```

The synthetic Gemma layer can also use block-seg2 plus A-cache:

```bash
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --execute \
    --operators gemma_decoder_layer \
    --test-env GEMMA_PROFILE_ELF=rvv_bf16_gemma_decoder_layer_profile_block_seg2_a_cache.elf \
    --test-env GEMMA_BLOCK_PACKED_PROJECTIONS=1 \
    --output-dir tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/results/z19_block_seg2_a_cache_decoder
```

Additional environment variables are written to
`data_reading_method.extra_test_env` so different software schedules for the
same Cocotb test remain distinguishable.

Parse existing logs without rerunning simulation:

```bash
python3 tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profile_gemma_operators.py \
    --workspace . \
    --from-log /path/to/bazel-test.log
```

The default output directory is `profiling/results/`:

- `raw_logs/*.log`: complete Bazel/Cocotb output and auditable evidence for each value.
- `profile_report.json`: structured results with source lines and readout methods.
- `profile_samples.csv`: one row per shape/configuration for spreadsheets, pandas, or plots.
- `profile_report.md`: a human-readable summary.
- `real_gemma_layer0_comparison.md`: an equal-condition comparison of the real
  Hugging Face Gemma layer 0, its 19 profiled stages, mcycle correction, and
  MAC/cycle formulas.

With `--execute`, Bazel output is shown in the terminal and saved to
`raw_logs/`. The first Verilator/Cocotb build may take a while, but the terminal
output identifies the current stage.

## Host compilation environment

The script uses the host toolchain discovered by Bazel and does not force the
repository's `host_clang_platform`. That platform may contain workstation-
specific LLVM paths and is not an appropriate implicit profiling dependency.
The script uses `bazel --batch` to avoid reusing a server with a stale
`JAVA_HOME`.

Standalone Gemma-layer operator collection uses Bazel `--test_filter` to run
the corresponding BF16 testcase. The script sets `GEMMA_PROFILE_ONLY=1` to
select the layer shapes used by the actual layer. Directly running the original
Cocotb target does not set this variable, so its default test coverage is
unchanged.

## Decoder profiling isolation

`profiled_decoder_layer/` contains the decoder profiling implementation with 19
per-stage cycle counters. Build and run it independently with:

```text
//tests/cocotb/rvv/ml_ops/gemma_kernels/profiling/profiled_decoder_layer:rvv_gemma_decoder_layer_profile_cocotb_test
```

The `decoder_layer/` correctness tests, source files, and Bazel targets remain
separate. Profiling uses independent ELFs so timing instrumentation does not
change the correctness-test body or overwrite its artifacts.
