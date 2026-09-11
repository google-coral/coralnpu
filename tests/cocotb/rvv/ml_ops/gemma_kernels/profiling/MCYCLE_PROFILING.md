# Gemma Decoder Layer `mcycle` Stage Profiling

This document describes the ownership and counting rules for `mcycle`, and
how to obtain reliable cycle data for sequential Gemma decoder-layer
operators. These are hardware clock cycles on the target RISC-V core, not
host-side Cocotb or Python time.

## Ownership

`mcycle` is maintained by the hardware CSR module, not by the C++ runner,
kernel, or Cocotb software.

| Layer | Responsibility | Location |
| --- | --- | --- |
| RTL | Store and increment the 64-bit counter; support CSR reads and writes | `hdl/chisel/src/coralnpu/scalar/Csr.scala` |
| C++ utility | Read a consistent 64-bit snapshot with `csrr` | `mcycle_read()` in `sw/utils/utils.h` |
| Decoder runner | Read timestamps at layer or stage boundaries and write deltas to ELF globals | `rvv_bf16_gemma_decoder_layer_profile_runner.cc`, `rvv_gemma_decoder_layer_profile.cc` |
| Cocotb | Read and validate values by ELF symbol address; it does not count cycles | `cocotb_tests/rvv_gemma_decoder_layer_profile_cocotb_test.py` |

The `Csr` RTL advances the counter. Timestamp boundaries in the profiling
runner determine which operator owns a cycle.

## RTL behavior

`Csr.scala` implements `mcycle` as a 64-bit register reset to zero:

```scala
val mcycle = RegInit(0.U(64.W))
...
mcycle := Mux(mcycle_written, mcycle_t, mcycle + 1.U)
```

For RV32:

- `mcycle` (CSR `0xB00`) reads and writes the low 32 bits.
- `mcycleh` (CSR `0xB80`) reads and writes the high 32 bits.
- A cycle without a CSR write performs `mcycle + 1`; a cycle that writes
  `mcycle` or `mcycleh` uses the written value and does not increment again.
- The low 32 bits wrap naturally and carry into the high 32 bits.

The current implementation has no `mcountinhibit` or retirement-based enable
condition. As long as the CSR clock runs, `mcycle` increments. It includes
memory stalls, pipeline stalls, function calls, and timing code. It differs
from `minstret`, which counts retired instructions.

## Consistent reads

An RV32 CSR read returns only 32 bits. `mcycle_read()` uses a high-low-high
sequence:

```text
high_1 = mcycleh
low    = mcycle
high_2 = mcycleh
if high_1 != high_2, retry
return (high_1 << 32) | low
```

If the low word wraps between reads, the high words differ. Retrying prevents
combining a pre-wrap high word with a post-wrap low word into a timestamp that
never existed. Store the result in `uint64_t` and use the unsigned difference
`end - start`.

## Sequential-stage measurements

For a sequential stage `op_i`:

```text
t_start = mcycle_read()
execute op_i
t_end   = mcycle_read()
C_raw(i) = t_end - t_start
```

`C_raw(i)` is the end-to-end stage count. It includes operator instructions,
RVV execution, memory accesses, pipeline waits, loops, tail handling, and
function calls, plus the small boundary cost of the two reads.

It excludes layer initialization before the start timestamp and the store to
`gemma_stage_cycles[]` after the end timestamp. Control code between stages,
such as computing `attention_length`, is not assigned to an individual stage;
it appears in the difference between whole-layer time and the stage sum.

If an operator submits asynchronous work and returns, the difference measures
submission cost. Place the end timestamp after completion or `wait` to measure
the full execution. The current decoder-layer kernels are sequential calls, so
function-call boundaries are sufficient.

## Decoder profiling stages

The profiling variant splits the call order into 19 stages:

```text
input RMSNorm
Q / K / V projection
Q RMSNorm / K RMSNorm / RoPE / cache append / FlashAttention
output projection / post-attention RMSNorm / residual add
pre-FFN RMSNorm / gate projection / up projection / Tanh-GELU x Up
down projection / post-FFN RMSNorm / final residual add
```

`rvv_gemma_decoder_layer_profile.cc` reads `mcycle` around each stage through
`PROFILE_STAGE` and stores the delta in `gemma_stage_cycles[stage]`. The runner
provides two modes:

- `kRunWholeLayer` calls `Gemma270mDecoderLayerBf16Whole()` without internal
  timestamps and measures the uninstrumented whole layer.
- `kRunProfiledStages` calls the version with 19 timestamp pairs and provides
  stage attribution.

Run both modes with identical inputs, weights, cache length, ELF layout, and
reset conditions. Instrumented timing changes code size and cache state, so do
not use it as the uninstrumented performance baseline.

The runner repeats an empty `mcycle_read(); mcycle_read();` interval 32 times
and keeps the minimum as `mcycle_read_overhead_cycles`:

```text
C_raw(i)       = stage_end - stage_start
C_corrected(i) = max(0, C_raw(i) - C_read_overhead)
```

The corrected value is useful for comparing short stages but is not an absolute
hardware truth. Keep both raw and corrected values for short stages such as
cache append and residual add; read overhead is usually small for large
GeMV/GEMM stages.

## Reporting recommendations

Report at least:

| Metric | Purpose |
| --- | --- |
| `whole_layer_cycles_raw` | End-to-end baseline without internal instrumentation |
| `stage_cycles_raw[i]` | Time between real stage boundaries |
| `mcycle_read_overhead_cycles` | Empty-read baseline |
| `stage_cycles_corrected[i]` | Approximate comparison for short stages |
| `sum(stage_cycles_raw)` | Sum of attributed stages |
| `whole_layer - sum(stage)` | Unattributed control overhead or instrumentation perturbation |
| Cache length, position, shape, and data location | Conditions needed to explain attention and memory variation |

For matrix stages, report `MACs / cycle` when useful. For RMSNorm, RoPE, GELU,
residual add, and cache append, prefer `cycles / element`. Do not force
non-matrix operators into MAC/cycle metrics.

Keep the BF16 kernel version, compiler flags, clock configuration, input shape,
cache length, memory regions, and DUT reset strategy fixed for comparisons.
FlashAttention depends on `cache_length + 1`, so report cache lengths separately.

## Implementation checklist

- Do not reset the counter for every operator; use differences from one
  free-running 64-bit `mcycle` timeline.
- Keep internal timestamps and deltas as `uint64_t`; exported 32-bit symbols
  silently truncate intervals above `2^32` cycles.
- If measured code becomes inline, add `asm volatile("" ::: "memory")` around
  timestamp reads. Asynchronous MMIO/DMA also needs the required RISC-V
  `fence` and completion wait.
- Keep `Gemma270mDecoderLayerBf16Whole()` separate from the profiled version.
- Read `cycle_count` and `gemma_stage_cycles` from ELF symbols in Cocotb rather
  than depending on simulator log formats or host wall-clock time.

## Verification checklist

- Use `perf_counters.cc` to verify `mcycle` read/write semantics and wraparound.
- Keep profiling and correctness ELFs separate.
- Run whole-layer and profiled-stage modes with identical inputs and resets.
- Confirm every output associated with `gemma_stage_cycles[i]` passes numerical
  correctness checks.
- Review raw and corrected values for short stages; prefer raw values for large
  stages.
- If a delta can exceed 32 bits, use 64-bit export and readout end to end.
