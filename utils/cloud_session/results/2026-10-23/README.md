# Verilator regression results, 2026-10-23

Every Verilator cocotb and Verilator UVM test target that CI runs (no
`manual` or `vcs` tags), run in a Claude Code cloud session: cocotb at commit
`5a88fe4`, UVM at `ad36d16` (which adds `-latomic` to `verilator_lib` in
`third_party/verilator/verilator.BUILD.bazel`; the UVM models already linked
it).

| Suite | Targets | Result | Simulated time |
| --- | --- | --- | --- |
| cocotb | 493 | 493 passed in Bazel; 500 testcases PASS, 1 target ran none | 67.05 ms |
| UVM | 820 | 820 passed; 820 programs PASS | 6.22 ms |

## Files

| File | Contents |
| --- | --- |
| `cocotb_results.log` | Totals, per-package table, testcases that did not pass, every testcase |
| `cocotb_results.csv` | One row per testcase: result, simulated time (ns), cocotb real time (s) |
| `uvm_results.log` | Totals, per-package table, failures, every program |
| `uvm_results.csv` | One row per program: result, failure reason, simulated time (ps) |
| `*_targets.txt` | The Bazel targets that were run |
| `*_bazel.log` | Bazel's own output from the runs |

Simulated times come from the simulators: cocotb's `SIM TIME (ns)` column, and
for UVM the time on the `** UVM TEST PASSED **` line, in ps (the testbench's
10 ns clock advances it by 10000 per cycle).

## Findings

`//tests/cocotb/tlul:banked_dtcm_cocotb_test_test_address_aliasing` passes
in Bazel but runs no testcase: cocotb prints "No tests left after filtering".
`BANKED_DTCM_TESTCASES` in `tests/cocotb/tlul/BUILD` lists
`test_address_aliasing`, which `test_banked_dtcm.py` does not define, and omits
`test_out_of_bounds`, which it does define, so that testcase never runs.

## How the runs differed from CI

- Host: 4 cores, Bazel 9.1.0, Verilator 5.052, clang-18 (the CI image uses
  clang-19).
- GitHub archive downloads were blocked. The `.tar.gz` dependencies were
  rebuilt byte-for-byte with `fill_gh_archives.py` and passed their sha256
  checks. The 14 GitHub `.zip` dependencies were rewritten with
  `local_zips.py`, so their sha256 was not checked: opentitan, coralnpu-mpact,
  tflite-micro, kissfft, rocket-chip, diplomacy, cvfpu, common_cells,
  fpu_div_sqrt_mvp, RVVI, libsystemctlm-soc, zlib, gnulib, riscv-tests.
- cocotb: the FreeRTOS target
  (`coralnpu_chisel_subsystem_highmem_cocotb_test_freertos_test_freertos`)
  could not fetch its dependency on the first pass and was re-run on its own;
  `cocotb_bazel.log` holds both passes. `core_mini_axi_csr_test` was re-run
  once more later, so its times in the results are from that run.
- UVM: the first attempt ran all 820 targets at once and filled the disk with
  runfiles trees. The first 100 targets passed in that attempt; the other 720
  were then run in batches of 40, deleting runfiles in between, which is what
  `run_regression.sh` now does. `uvm_bazel.log` holds the first 100 and the 18
  batches; its "No space left on device" lines come from the first attempt.

## Reproducing

```bash
python3 -I utils/cloud_session/fill_gh_archives.py --repo .
# Only where GitHub .zip archives are blocked (skips their sha256 check):
python3 -I utils/cloud_session/local_zips.py --i-understand-this-skips-sha256 --all
utils/cloud_session/run_regression.sh cocotb /tmp/regression
utils/cloud_session/run_regression.sh uvm /tmp/regression
# then run the `git checkout -- ...` line local_zips.py printed
```
