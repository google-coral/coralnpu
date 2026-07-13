# Coral NPU

Coral NPU is a hardware accelerator for ML inferencing. Coral NPU is an Open Source IP designed by Google Research and is freely available for integration into ultra-low-power System-on-Chips (SoCs) targeting wearable devices such as hearables, augmented reality (AR) glasses and smart watches.

Coral NPU is a neural processing unit (NPU), also known as an AI accelerator or deep-learning processor. Coral NPU is based on the 32-bit RISC-V Instruction Set Architecture (ISA).

Coral NPU includes three distinct processor components that work together: matrix, vector (SIMD), and scalar.

![Coral NPU Archicture](doc/images/arch_data_flow.png)
[Coral NPU Architecture Datasheet](https://developers.google.com/coral/guides/hardware/datasheet)

## Coral NPU Features
Coral NPU offers the following top-level feature set:

* RV32IMF_Zve32x RISC-V instruction set (specifically `rv32imf_zve32x_zicsr_zifencei_zbb`)
* 32-bit address space for applications and operating system kernels
* Four-stage processor, in-order dispatch, out-of-order retire
* Four-way scalar, two-way vector dispatch
* 128-bit SIMD, 256-bit (future) pipeline
* 8 KB ITCM memory (tightly-coupled memory for instructions)
* 32 KB DTCM memory (tightly-coupled memory for data)
* Both memories are single-cycle-latency SRAM, more efficient than cache memory
* AXI4 bus interfaces, functioning as both manager and subordinate, to interact with external memory and allow external CPUs to configure Coral NPU

## Prerequisites

Everything is driven by **Bazel**; most tools (firtool/CIRCT, the RISC-V GCC toolchain,
Verilator, tflite-micro) are fetched hermetically, so the host prerequisites are small.

| Tool | Version | Needed for | Install |
| --- | --- | --- | --- |
| **Bazel** | **8.6.0** (pinned in `.bazelversion`) | everything | use `bazelisk` (below) — it auto-fetches the pinned version |
| **Python** | 3.9–3.12 | cocotb / build scripts | a dedicated conda env or `venv` — see [Python environment](#python-environment) |
| **SRecord** | any | *optional* — only the ELF→`.vmem` firmware step | system package (`apt install srecord`) or [source](https://srecord.sourceforge.net/); not on conda-forge |
| **Synopsys VCS + Verdi** | 2023.12 | *optional* — VCS sim & the UVM cosim | site license (see the DCS Lab note below); Verilator needs no license |

> The upstream README lists Bazel 7.4.1 — this fork pins **8.6.0** in `.bazelversion`. Trust the file.

### Install Bazel (bazelisk)

```bash
mkdir -p ~/bin
curl -fsSL -o ~/bin/bazel \
  https://github.com/bazelbuild/bazelisk/releases/latest/download/bazelisk-linux-amd64
chmod +x ~/bin/bazel
export PATH="$HOME/bin:$PATH"      # add to your shell rc
bazel version                       # first run downloads Bazel 8.6.0 per .bazelversion
```

### Python environment

Any Python 3.9–3.12 works. Create a **dedicated environment** so nothing conflicts with your
system Python. The only host package the build/test scripts need is **numpy** — everything else
(cocotb, the RISC-V toolchain, tflite-micro, …) is fetched hermetically by Bazel.

```bash
# Option A — conda
conda create -n coralnpu python=3.11 numpy -y
conda activate coralnpu

# Option B — venv
python3 -m venv ~/.venvs/coralnpu
source ~/.venvs/coralnpu/bin/activate
pip install numpy
```

Optional, only for the on-hardware / FPGA loaders: `pip install pyelftools pyocd`.
(This matches the project's own CI image, `utils/coralnpu.dockerfile`, which installs
`python3` + `python3-numpy`.)

## Environment setup — NTU DCS Lab

Two extra steps are needed **only** for the VCS/Verdi flow on the lab machines. The
license-free Verilator flow needs none of this.

1. **Source the VCS/Verdi environment.** `cvsd.cshrc` is a **csh** script, so source it in
   tcsh and drop to bash, then activate Python:

   ```bash
   tcsh -c 'source ~/cvsd.cshrc; exec bash'        # sets VCS_HOME / VERDI_HOME / LM_LICENSE_FILE
   conda activate coralnpu                          # the env you created above
   ```

2. **Sanitize `LD_LIBRARY_PATH` (important).** `cvsd.cshrc` prepends Cadence/Innovus and
   Verdi-bundled `libstdc++` dirs. That old `libstdc++` lacks `CXXABI_1.3.11` and **crashes the
   Bazel launcher**. Remove those entries (keep the VCS/Verdi-PLI and system dirs):

   ```bash
   LD_LIBRARY_PATH=$(echo "$LD_LIBRARY_PATH" | tr ':' '\n' \
     | grep -viE 'cadence|INNOVUS|verdi.*etc/lib/libstdc\+\+' | paste -sd:)
   export LD_LIBRARY_PATH
   ```

## Building & running

### Verilator — the default, no license required

```bash
# Run the cocotb test suite (builds the Verilator model on the fly)
bazel run //tests/cocotb:core_mini_axi_sim_cocotb

# Build a firmware binary and run it on the standalone Verilator sim
bazel build //examples:coralnpu_v2_hello_world_add_floats
bazel build //tests/verilator_sim:core_mini_axi_sim
ELF=$(find -L bazel-out -name 'coralnpu_v2_hello_world_add_floats.elf' | head -1)
bazel-bin/tests/verilator_sim/core_mini_axi_sim --binary "$ELF"
```

### Emit the SystemVerilog handoff (Chisel → firtool)

```bash
# The AXI scalar core as flattened SystemVerilog — the SoC/ASIC integration handoff
bazel build //hdl/chisel/src/coralnpu:core_mini_axi_cc_library_emit_verilog
```

### VCS — RTL simulation (needs the environment above)

VCS targets are skipped by default (`.bazelrc` sets `--build_tag_filters=-vcs`); pass an empty
filter to enable them.

```bash
# Build the lightest VCS sim (non-RVV) and a test program
bazel build --build_tag_filters= //tests/vcs_sim:core_mini_axi_sim
bazel build //tests/cocotb:nop_test.elf

# Run it — give enough cycles for the program to reach its halt/WFI
ELF=$(find -L bazel-out -name 'nop_test.elf' | head -1)     # -L follows the bazel-out symlink
bazel-bin/tests/vcs_sim/core_mini_axi_sim --binary "$ELF" --cycles=500000
#   -> "Simulator halted successfully."

# Canonical VCS smoke test (builds the RVV verification variant)
bazel test --build_tag_filters= --test_tag_filters= \
  //tests/vcs_sim:simulators_smoke_test
```

> **Pass/fail:** every exit in `tests/vcs_sim/top.sv` calls `$finish` (VCS returns 0), so the
> **printed message is the verdict** — `"Simulator halted successfully."` = pass;
> `"...timed out"` / `"...fault condition"` = fail. The `--cycles` limit must be high enough for
> the program to finish (e.g. `nop_test` runs 51,200 nops and needs ~500k cycles).

### UVM co-simulation (VCS + MPACT golden model)

```bash
cd tests/uvm && make            # see tests/uvm/README.md; set CORALNPU_MPACT for the ISS
```

### Lint

```bash
utils/run_linters.sh            # verilog/scala/python/shell linters used in CI
```

### Handy targets

| Goal | Command |
| --- | --- |
| Full test suite (Verilator) | `bazel run //tests/cocotb:core_mini_axi_sim_cocotb` |
| Emit core SystemVerilog | `bazel build //hdl/chisel/src/coralnpu:core_mini_axi_cc_library_emit_verilog` |
| VCS sim (opt-in) | `bazel build --build_tag_filters= //tests/vcs_sim:core_mini_axi_sim` |
| VCS smoke test | `bazel test --build_tag_filters= --test_tag_filters= //tests/vcs_sim:simulators_smoke_test` |
| Build a firmware ELF | `bazel build //examples:coralnpu_v2_hello_world_add_floats` |
| Lint | `utils/run_linters.sh` |

More: [`doc/simulation.md`](doc/simulation.md) · [`doc/integration_guide.md`](doc/integration_guide.md) ·
[`doc/tutorials/`](doc/tutorials/) · [`tests/uvm/README.md`](tests/uvm/README.md) ·
[Integrating a new IP](doc/tutorials/integrating_new_ip.md)

## Extending Coral NPU — add your own IP

Adding a compute accelerator (CNN / MatMul / GEMM engine), a custom vector/tensor instruction, or a
small SIMD ALU op? The step-by-step guide below covers **which files to change and how**, with
copy-pasteable code for all three integration paths — a memory-mapped **bus device (MMIO + DMA)**, a
**custom RVV instruction / backend** extension, and an **in-core functional unit** — plus how to
build, test (cocotb), and drive the IP from firmware:

**→ [`doc/tutorials/integrating_new_ip.md`](doc/tutorials/integrating_new_ip.md)**


![](doc/images/Coral_Logo_200px-2x.png)
