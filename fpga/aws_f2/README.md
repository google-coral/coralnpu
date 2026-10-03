# Coral NPU bootstrap CL on AWS F2

This directory contains an AWS F2 customer-logic (CL) wrapper and host runner
for `RvvCoreMiniAxi`. The host loads a 32-bit RISC-V ELF into the NPU over the
OCL PCI BAR, starts the core, waits for it to halt, and can read result symbols
back from ITCM or DTCM.

This is a bootstrap configuration: the NPU manager port is not connected to
HBM, so programs must fit entirely in ITCM and DTCM. Model-resident Gemma
inference needs a separate CL that connects the manager port to external
memory.

## Build and stage the CL

Set up an AWS FPGA HDK checkout, generate the production RTL, and stage the
sources into a new HDK example:

```bash
source "$AWS_FPGA_REPO_DIR/hdk_setup.sh"
bazel build --repo_env=CC=/usr/bin/gcc \
  //hdl/chisel/src/coralnpu/prod:rvv_core_mini_axi_prod_cc_library_emit_verilog
AWS_FPGA_DIR="$AWS_FPGA_REPO_DIR" fpga/aws_f2/scripts/stage_cl.sh
```

Build the design checkpoint using the normal AWS HDK flow:

```bash
cd "$AWS_FPGA_REPO_DIR/hdk/cl/examples/cl_coralnpu/build/scripts"
./aws_build_dcp_from_cl.py -c cl_coralnpu --mode small_shell --no-encrypt
```

Create an AFI from the resulting checkpoint and load it into an F2 slot using
the standard `aws-fpga` image-management flow.

## Build and run the host utility

After sourcing `sdk_setup.sh`, build the runner from the staged runtime
directory:

```bash
source "$AWS_FPGA_REPO_DIR/sdk_setup.sh"
make -C "$AWS_FPGA_REPO_DIR/hdk/cl/examples/cl_coralnpu/software/runtime"
sudo "$AWS_FPGA_REPO_DIR/hdk/cl/examples/cl_coralnpu/software/runtime/coralnpu_runner" \
  --slot 0 --verify --read result:4 path/to/program.elf
```

`--verify` reads every loaded word back through the PCI BAR before execution.
`--read SYMBOL[:WORDS]` reads a global ELF symbol after the NPU halts.

## Verify that execution is on the FPGA

Before running the ELF, verify that the instance and FPGA slot are ready:

```bash
curl -fsS http://169.254.169.254/latest/meta-data/instance-type
sudo fpga-describe-local-image -S 0 -H
lspci -nn -s 34:00.0
```

The instance type must be an F2 type and `fpga-describe-local-image` must show
the intended AFI in the `loaded` state. A `cleared` slot or `No AFI` means no
customer logic is executing.

The runner calls `fpga_pci_attach`, then uses `fpga_pci_poke` and
`fpga_pci_peek` on APP PF BAR0 for all ELF loads, control writes, status polls,
and result reads. The x86 CPU performs this orchestration, but the RISC-V ELF
executes in the Coral NPU instantiated in FPGA customer logic. A successful
run should therefore show all of the following:

1. The AFI remains `loaded` before and after the run.
2. `--verify` completes without a BAR readback mismatch.
3. The runner reports a start PC and `halted status=0x00000001`.
4. `--read` returns the expected program result from NPU memory.
