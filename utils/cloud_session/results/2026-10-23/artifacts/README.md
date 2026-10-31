# Build outputs of the 2026-10-23 regression

The binaries the regression in `..` ran on, packaged by
`utils/cloud_session/package_artifacts.py`. They were built for x86-64 Linux
(Ubuntu 24.04, glibc 2.39) with clang-18 and Verilator 5.052.
`MANIFEST.sha256` lists the sha256 of every file inside the archives.

| Archive | Contents |
| --- | --- |
| `uvm_model.tar.gz` | `uvm/uvm_sim_verilator_vme`, the Verilator UVM testbench model with `VmeCoreMiniVerificationAxi` and Spike co-simulation linked in, and `uvm/uvm_batch_list.txt`, the 820 UVM programs |
| `elfs.tar.gz` | `elfs/`: the RISC-V test programs (876 files) the cocotb and UVM tests load |
| `cocotb_models.tar.gz` | `cocotb/`: the 24 Verilator models the cocotb tests drive (`<package>/<Top>_build/<Top>`) |
| `rtl.tar.gz` | `rtl/`: the generated SystemVerilog of the cores and SoC test harnesses |

## Running the UVM model without Bazel

Extract `uvm_model.tar.gz` and `elfs.tar.gz` into one directory, then:

```bash
./uvm/uvm_sim_verilator_vme +UVM_TESTNAME=coralnpu_regression_test \
  +UVM_VERBOSITY=UVM_LOW +REGRESSION_LIST=uvm/uvm_batch_list.txt \
  +TEST_ELF=dummy +TEST_TIMEOUT=100000 "+MISA_VALUE='h40801120'"
```

Each line of the list is `<elf> <tohost> <entry> <timeout> <SPIKE|NONE>
<label>`; take a subset of lines to run fewer programs. The model prints
`** UVM TEST PASSED **` or `** UVM TEST FAILED **` for each program. Simulated
time (ps) carries on from one program to the next within a run, so a program's
own time is the difference between its end and the previous program's end.
For example, running hello-world, `rvv_matmul_assembly` and `rv32ui-p-simple`
in that order ends them at 2850000, 796550000 and 796860000 ps.

## cocotb models

The cocotb models are Verilator executables that load cocotb's
`libcocotbvpi_verilator.so` and run the Python tests in `tests/cocotb`; they do
not run on their own. Run the cocotb tests through Bazel
(`utils/cloud_session/run_regression.sh cocotb ...`), which rebuilds them.
