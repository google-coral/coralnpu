# Verilator regression results, 2026-10-24: VME with 256 PEs

The same regressions as `../2026-10-23`, rerun after commit `191808c`, which
builds the VME cores (`VME_CORE_MINI_AXI_COMMON_GEN_FLAGS`) with
`--vmeProcessDelay=1`: the Zvt PE array computes a 16 x 16 tile in 1 cycle
with 256 PEs, instead of 4 cycles with 64. The runs used commit `1118e6e`
with `REGRESSION_NOCACHE=1`, so every test ran again. The generated
`VmeCoreMiniAxi.sv` defines `ZVT_PROCESS_DELAY 1`.

| Suite | Targets | Result | Simulated time | 2026-10-23 |
| --- | --- | --- | --- | --- |
| cocotb | 493 | 493 passed in Bazel; 500 testcases PASS, 1 target ran none | 67.07 ms | same pass status, 67.05 ms |
| UVM | 831 | 831 passed; 831 programs PASS | 6.24 ms | 820 of 820 passed, 6.22 ms |

No test changed result. The cocotb target that runs no testcase is the same
`banked_dtcm_cocotb_test_test_address_aliasing` described in
`../2026-10-23/README.md`.

## UVM: 11 more targets

`//fpga` has 11 `verilator_batch_uvm_test` targets (`collect_coralnpu_elfs()`
in `fpga/BUILD`) that were not in the 2026-10-23 target list, although
`fpga/` has not changed since then. All 11 pass (16.98 us). On the 820
targets both runs share, the total is 6,221,430,000 ps against
6,221,810,000 ps.

## Simulated time of the VME tests

UVM simulation is deterministic, so the only changes are the 3 VME programs
whose time depends on the PE array (10 ns per cycle). The other 817 shared
programs take the same time as before.

| UVM program | 64 PEs (ps) | 256 PEs (ps) | Cycles |
| --- | --- | --- | --- |
| `vme_matmul_test` | 60,870,000 | 60,610,000 | -26 |
| `vme_mstatus_ms_test` | 20,420,000 | 20,310,000 | -11 |
| `vme_mset_vtmmu_sequence_test` | 1,650,000 | 1,640,000 | -1 |

cocotb VME testcases (1.25 ns per cycle):

| cocotb testcase | 64 PEs (ns) | 256 PEs (ns) | Cycles |
| --- | --- | --- | --- |
| `vme_matmul_int8_test` | 4785.00 | 4767.50 | -14 |
| `vme_matmul_bf16_test` | 3761.25 | 3746.25 | -12 |
| `vme_mstatus_ms_test` | 6361.25 | 6347.50 | -11 |
| `vme_matmul_fp32_test` | 1811.25 | 1803.75 | -6 |
| `vme_msettm_matmul_test` | 1026.25 | 1022.50 | -3 |
| `vme_mset_vtmmu_sequence_test` | 236.25 | 235.00 | -1 |

The other 9 VME testcases take the same time. Each tile saves 3 cycles, but
these tests run only a few tiles between loads, stores and checks, so the
total changes by under 1%. Other cocotb tests also changed time; those are
randomized tests (DMA, TL-UL, random instructions, gdbserver) whose stimulus
differs between runs.

## Files

As in `../2026-10-23`, plus `cocotb_results.json`, the per-testcase rows that
`parse_cocotb_results.py` also writes. The build outputs were not committed
again.

## Reproducing

```bash
REGRESSION_NOCACHE=1 utils/cloud_session/run_regression.sh cocotb /tmp/regression
REGRESSION_NOCACHE=1 utils/cloud_session/run_regression.sh uvm /tmp/regression
```

with the dependency setup in `../2026-10-23/README.md`.
