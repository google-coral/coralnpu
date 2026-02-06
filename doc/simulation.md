# Simulation

CoralNPU supports using either VCS simulator or DSim.

## VCS Support

To enable VCS support, the following environment variables need to be set:

```
export VCS_HOME=${PATH_TO_YOUR_VCS_HOME}
export LM_LICENSE_FILE=${YOUR_LICENSE_FILE}
```

`LD_LIBRARY_PATH` and `PATH` should also be updated.

```
export LD_LIBRARY_PATH="${VCS_HOME}"/linux64/lib
export PATH=$PATH:${VCS_HOME}/bin/
```

A VCS simulation can defined with the `vcs_testbench_test` rule. For example
use in a BUILD file:

```
load("//rules:vcs.bzl", "vcs_testbench_test")

vcs_testbench_test(
    name = "foobar_tb",
    srcs = ["Foobar_tb.sv"],
    module = "Foobar_tb",
    deps = ":foobar",
)
```

By default, we disable VCS within bazel. Invoke
`bazel {build,run,test} --config=vcs` to enable VCS support.

## DSim Support

### Prerequisites
1. Ensure that Docker is installed and available for use.
2. Download the DSim binary (`AltairDSim2025.0.1_linux64.bin`) into `utils/`.
3. Place your DSim license JSON file (`dsim-license.json`) into `utils/`.
4. Clone `coralnpu-mpact`.
5. Set the following environment variable:
```
export CORALNPU_MPACT=${PATH_TO_coralnpu-mpact}
```

### Build Images
```
docker build --platform linux/amd64 -f utils/coralnpu-dsim.dockerfile -t coralnpu-dsim .
```

### Launch Container
```
docker run -it --platform linux/amd64 -v $(pwd):/workspace -w /workspace coralnpu-dsim
```

### Compile UVM Testbench
```
cd tests/uvm
make compile
```

### Run Tests
```
cp <path to your ELF file> tests/uvm/bin
make run TEST_ELF=./bin/<test>.elf
```

### Outputs
- Logs: `sim_work/logs/`
- Waves: `sim_work/waves/`