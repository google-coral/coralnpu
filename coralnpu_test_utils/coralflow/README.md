# CoralFlow Functional Guide

CoralFlow is CoralNPU's unified, single-source verification and hardware-execution framework. Instead of maintaining separate test harnesses for the functional simulator (MPACT NPUSim), RTL simulators (Verilator / VCS Cocotb), UVM co-simulation, and physical FPGA boards, you write a single Python test function against an abstract `fixture` interface.

## 1.Workflow

Every CoralFlow test follows a four-step lifecycle:

1. **Load ELF and resolve symbols**: `await fixture.load_elf_and_lookup_symbols(elf_path, symbols)`
2. **Write inputs to memory**: `await fixture.write("input_buf", data)` / `await fixture.write_word("len", n)`
3. **Run core until halt**: `await fixture.run_to_halt()`
4. **Read outputs and assert**: `out = await fixture.read("output_buf", dtype=np.int32, shape=(n,))`

```text
+-----------------------------------------------------------------------+
|       Single-Source Python Test (@coralflow_test + coralflow_main)    |
+-----------------------------------------------------------------------+
                                    |
                                    v
+-----------------------------------------------------------------------+
|         CoralFlow Runner (coralnpu_test_utils/coralflow/runner.py)    |
+-----------------------------------------------------------------------+
       |                    |                       |                 |
       | npusim             | verilator / vcs       | uvm             | nexus_fpga
       v                    v                       v                 v
+--------------+   +--------------------+   +---------------+   +---------------+
| MpactNpuSim  |   | VerilatorTest      |   | UvmTest       |   | FpgaTest      |
| TestFixture  |   | Fixture (Cocotb)   |   | Fixture       |   | Fixture (SPI) |
+--------------+   +--------------------+   +---------------+   +---------------+
```

## 2. Navigating the Codebase

To understand how CoralFlow works across each simulation and hardware backend, explore the codebase in three layers:

### Layer 0: Core Protocol and Runner (`coralnpu_test_utils/coralflow/`)

- [`base_fixture.py`](base_fixture.py): Defines `CoralNPUFixtureProtocol` and `BaseCoralNPUFixture`. Inspect this file for the canonical API available on `fixture` (`load_elf_and_lookup_symbols`, `write`, `write_word`, `write_ptr`, `read`, `read_word`, `run_to_halt`, `get_cycle_count`).
- [`runner.py`](runner.py): Implements `@coralflow_test` and `coralflow_main()`. It detects whether execution is inside a Cocotb simulator VM or standard Python (`asyncio`), instantiates the backend fixture selected by `CORALFLOW_TARGET` or `--backend`, and handles testcase filtering (`--testcase` / `--test_filter`).
- [`run_fpga_pkg.sh`](run_fpga_pkg.sh) and [`standalone_runfiles.py`](standalone_runfiles.py): Support standalone FPGA tarball execution on lab hosts without Bazel.

### Layer 1: Shared ELF and Memory Utilities (`coralnpu_test_utils/sim_backends/`)

- [`common_utils.py`](../sim_backends/common_utils.py): Shared across all backends for parsing ELF symbol tables (`parse_elf_symbols`), checking Highmem vs. Lowmem linker origins (`get_elf_dtcm_origin`), resolving Bazel runfiles (`resolve_runfile_path`), and reconstructing typed NumPy arrays from raw byte buffers (`reconstruct_read_data`).

### Layer 2: Backend Fixture Implementations (`coralnpu_test_utils/sim_backends/`)

| Backend | Fixture File | Underlying Mechanism |
| :--- | :--- | :--- |
| **`npusim`** | [`mpact_npusim_test_fixture.py`](../sim_backends/mpact_npusim_test_fixture.py) | Wraps `CoralNPUV2Simulator` (MPACT-Sim C++/pybind11 functional ISS in [`sw/coralnpu_sim/`](../../sw/coralnpu_sim)). Executes millions of instructions per second in-process. |
| **`verilator`** / **`vcs`** | [`verilator_test_fixture.py`](../sim_backends/verilator_test_fixture.py) | Wraps [`CoreMiniAxiInterface`](../core_mini_axi_interface.py). Drives cycle-accurate AXI transactions into the Chisel-generated RTL model inside Cocotb. |
| **`uvm`** | [`uvm_test_fixture.py`](../sim_backends/uvm_test_fixture.py) | Stages Python `write()` buffers into a temporary ELF image, launches the SystemVerilog UVM testbench ([`tests/uvm/`](../../tests/uvm/README.md)) with Spike lock-step co-simulation, and parses the post-halt SRAM dump for Python `read()` assertions. |
| **`nexus_fpga`** | [`fpga_test_fixture.py`](../sim_backends/fpga_test_fixture.py) | Communicates with a physical Nexus FPGA board via [`FtdiSpiMaster`](../ftdi_spi_master.py) and the C++ [`nexus_loader`](../../sw/utils/nexus_loader/main.cc) binary over FTDI USB-to-SPI. |

## 3. Generated Bazel Targets

Defined in [`rules/coralflow_test.bzl`](../../rules/coralflow_test.bzl), a single `coralflow_test(name = "my_test", ...)` declaration expands into the following Bazel targets:

| Generated Target | Rule Type | Description and Usage |
| :--- | :--- | :--- |
| **`:my_test_npusim`** | `py_test` | Fast functional simulation on MPACT-Sim (`bazel test //pkg:my_test_npusim`). |
| **`:my_test_verilator`** | `verilator_cocotb_test` | Cycle-accurate RTL simulation on Verilator (`bazel test //pkg:my_test_verilator`). |
| **`:my_test_vcs`** | `vcs_cocotb_test` | Cycle-accurate RTL simulation on Synopsys VCS (`bazel test --config=vcs //pkg:my_test_vcs`). |
| **`:my_test_uvm`** | `py_test` | SystemVerilog UVM + Spike + MPACT lock-step co-simulation (`bazel test //pkg:my_test_uvm`). |
| **`:my_test_nexus_fpga`** | `py_binary` | Direct hardware runner for an attached Nexus FPGA board (`bazel run //pkg:my_test_nexus_fpga -- --usb-serial <usb_serial> --highmem --verify`). |
| **`:my_test_nexus_fpga_pkg`** | `pkg_tar` (`.tar`) | Self-contained tarball (`my_test_nexus_fpga_pkg.tar`) with `run.sh`, `nexus_loader`, and ELFs for running on a lab host without Bazel (`bazel build //pkg:my_test_nexus_fpga_pkg`). |

When `testcases = [...]` contains multiple testcases, `_verilator` and `_vcs` also generate per-testcase sub-targets (`:my_test_verilator_<testcase>`) and group them under a `test_suite` named `:my_test_verilator` / `:my_test_vcs` for parallel execution.

## 4. Restricting Targets, Filtering Testcases, and Using Tags

### Restricting Generated Backends (`targets`)

By default, `coralflow_test` enables:

- **`highmem = False` (default)**: `["npusim", "verilator", "vcs", "uvm", "nexus_fpga"]`
- **`highmem = True`**: `["npusim", "verilator", "vcs", "nexus_fpga"]` (UVM is omitted by default for Highmem tests because the UVM DUT uses the standard 8KB ITCM / 32KB DTCM memory map).

To restrict a test to specific backends, pass `targets` explicitly in your `BUILD` file:

```python
coralflow_test(
    name = "conv_sim_test",
    srcs = ["conv_test.py"],
    elf = ":conv_test.elf",
    highmem = True,
    targets = [
        "npusim",
        "nexus_fpga",
    ],
)
```

### Excluding Testcases per Backend (`exclude_testcases`)

If a Python test module defines multiple `@coralflow_test` functions and specific cases are too large for Verilator or unsupported on a particular backend, use `exclude_testcases`:

```python
coralflow_test(
    name = "cocotb_conv2d",
    srcs = ["cocotb_conv2d.py"],
    elf = ":conv2d_test.elf",
    highmem = True,
    testcases = [
        "test_conv2d_4x1_h2w2",
        "test_conv2d_16x16",
    ],
    exclude_testcases = {
        "verilator": ["test_conv2d_16x16"],
    },
)
```

### Using Bazel Tags

Each generated target is automatically tagged by backend:

- `:<name>_npusim`: `["npusim", "fast"]`
- `:<name>_verilator`: `["verilator", "rtl"]`
- `:<name>_vcs`: `["vcs", "rtl", "vcs_cocotb_single_test"]`
- `:<name>_uvm`: `["uvm", "rtl"]`
- `:<name>_nexus_fpga` and `:<name>_nexus_fpga_pkg`: `["nexus_fpga", "manual"]`

Common Bazel tag filtering commands:

```bash
# Run only fast functional NPUSim tests across the repository:
bazel test --test_tag_filters=npusim //...

# Run only Verilator RTL tests:
bazel test --test_tag_filters=verilator //...

# Run only UVM co-simulation tests:
bazel test --test_tag_filters=uvm //...

# Run a single testcase inside a multi-testcase CoralFlow file:
bazel test //tests/cocotb:rvv_ml_ops_cocotb_test_npusim --test_filter=core_mini_rvv_matmul_c_test
```

To exclude a long-running test from wildcard `bazel test //...` runs unless explicitly requested, add `tags = ["manual"]` to `coralflow_test(...)`.
