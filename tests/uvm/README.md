# CoralNPU UVM Testbench

This document describes the structure and usage of the UVM testbench for
verifying the `RvvCoreMiniVerificationAxi` DUT.

## Overview

This testbench provides a basic UVM environment to:

* Instantiate the `RvvCoreMiniVerificationAxi` DUT.
* Connect AXI Master, AXI Slave, and IRQ interfaces to the DUT.
* Provide basic stimulus generation via UVM sequences.
* Include a simple reactive AXI Slave model.
* Load a binary file into the DUT's memory using backdoor access.
* Kick off the DUT execution using initial AXI writes.
* Check for basic test completion via DUT status signals (`halted`, `fault`) or
  a timeout.

## Prerequisites

* **Synopsys VCS:** This testbench is configured to run with Synopsys VCS.
* **UVM:** VCS needs to be configured with UVM 1.2 support enabled.
* **CoralNPU Hardware Repository:** Access to the repository containing the
  `RvvCoreMiniVerificationAxi` source code is required to generate the DUT
  Verilog and the test binary.
* **Bazel:** The build system used to generate the Verilog from the Chisel
  source in the CoralNPU HW repository.
* **RISC-V Toolchain:** A RISC-V toolchain compatible with the CoralNPU
  project is needed to generate the `.elf` file.
* **CoralNPU MPACT Repository:** Set the `CORALNPU_MPACT` environment
  variable to the absolute path of the `coralnpu-mpact` repository. This
  is required for co-simulation.

## Generating the Test Binary (program.elf)

The test program run by the DUT needs to be compiled to an elf format.

1. Navigate to the CoralNPU HW repository root:

   ```bash
   cd /path/to/your/coralnpu/hw/repo
   ```

2. Run the Bazel build command to compile the test program:

   ```bash
   bazel build //tests/cocotb/tutorial:coralnpu_v2_program
   ```

3. The `coralnpu_v2_program.elf` file is generated in the bazel output directory.
4. Copy this `coralnpu_v2_program.elf` file to the `bin/` directory of this UVM testbench structure (or update the `TEST_ELF` path in the `Makefile` or run command).

## Directory Structure

The testbench follows a standard UVM directory structure:

```text
.
├── common/                  # Common components
│   ├── coralnpu_axi_master/ # Files related to the TB acting as AXI Master
│   │   ├── coralnpu_axi_master_if.sv
│   │   └── coralnpu_axi_master_agent_pkg.sv
│   ├── coralnpu_axi_slave/  # Files related to the TB acting as AXI Slave
│   │   ├── coralnpu_axi_slave_if.sv
│   │   └── coralnpu_axi_slave_agent_pkg.sv
│   ├── coralnpu_irq/        # Files related to the IRQ/Control interface
│   │   ├── coralnpu_irq_if.sv
│   │   └── coralnpu_irq_agent_pkg.sv
│   └── transaction_item/    # Transaction item definitions
│       └── transaction_item_pkg.sv
├── env/                     # UVM Environment definition
│   └── coralnpu_env_pkg.sv
├── tb/                      # Top-level testbench module
│   └── coralnpu_tb_top.sv
├── tests/                   # UVM Tests and Sequences
│   └── coralnpu_test_pkg.sv
├── coralnpu_dv.f            # File list for compilation
└── bin/                     # Directory for test binaries
    └── program.elf          # (Needs to be generated and copied here)
```

## Running the Testbench using Bazel

The UVM testbench models and regressions are built and run directly using Bazel.

**1. Compiling the Simulator Models:**

* **Verilator Model:**

  ```bash
  bazel build //tests/uvm:uvm_sim_verilator
  ```

* **VCS Model:**

  ```bash
  bazel build --config=vcs //tests/uvm:uvm_sim_vcs
  ```

**2. Running UVM Regressions via Bazel:**

* **Verilator Single Test:**

  ```bash
  bazel test //tests/cocotb:uvm_regression_nop_test
  ```

* **VCS Single Test:**

  ```bash
  bazel test --config=vcs //tests/cocotb:vcs_uvm_regression_nop_test
  ```

* **Full Regression Suite:**

  ```bash
  # Verilator
  bazel test --test_tag_filters=uvm-regression //tests/cocotb:all

  # VCS
  bazel test --config=vcs --test_tag_filters=vcs-uvm-regression //tests/cocotb:all
  ```

**3. Running Regressions via `run_uvm_regression.py`:**

You can also run batch or targeted regressions using the Python runner:

```bash
# Run with Verilator
python3 utils/run_uvm_regression.py --simulator=verilator --target=//tests/cocotb:nop_test

# Run with VCS
python3 utils/run_uvm_regression.py --simulator=vcs --target=//tests/cocotb:nop_test
```

**4. Running on the VME (Zvt) Toplevel:**

The bench can instantiate `VmeCoreMiniVerificationAxi` (RVV plus the Zvt
matrix extension) instead of `RvvCoreMiniVerificationAxi`. The VME models
(`//tests/uvm:uvm_sim_verilator_vme`, `//tests/uvm:uvm_sim_vcs_vme`) are built
with `+define+ZVT_ON`, which enables the Zvt datapath in the RTL, selects the
VME DUT in `coralnpu_tb_top`, and configures the MPACT co-simulator for the
M4 (Zvt) architecture.

All generated regression targets pick their model through the
`//tests/uvm:dut` flag (`rvv` by default), so the existing regressions can be
rerun on the VME toplevel without separate targets:

```bash
# Verilator
bazel test --//tests/uvm:dut=vme --test_tag_filters=verilator-uvm-regression //...

# Python runner
python3 utils/run_uvm_regression.py --simulator=verilator --dut=vme --target=//tests/cocotb:nop_test
```
