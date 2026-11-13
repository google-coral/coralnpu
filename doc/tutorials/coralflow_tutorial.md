# Building and Simulating a Program with CoralFlow

This tutorial walks through writing a C++ CoralNPU program, creating a single-source CoralFlow Python testbench, and running it across **NPUSim**, **Verilator RTL**, **UVM**, and **Nexus FPGA**.

For an architectural overview of CoralFlow and its backends, see the [CoralFlow Functional Guide](../../coralnpu_test_utils/coralflow/README.md).

## 1. Write the C++ CoralNPU Program (`add_kernel.cc`)

Create a C++ program that exposes its input and output buffers as `extern "C"` globals in `.data` (DTCM). When `main()` returns `0`, the CoralNPU startup runtime (`coralnpu_start.S`) executes `mpause` to halt the core.

```cpp
// add_kernel.cc
#include <stdint.h>

extern "C" {
uint32_t in_buf_1[8] __attribute__((section(".data"), aligned(16)));
uint32_t in_buf_2[8] __attribute__((section(".data"), aligned(16)));
uint32_t out_buf[8] __attribute__((section(".data"), aligned(16)));
}

int main() {
  for (int i = 0; i < 8; ++i) {
    out_buf[i] = in_buf_1[i] + in_buf_2[i];
  }
  return 0;
}
```

## 2. Write the CoralFlow Python Test (`test_add_kernel.py`)

Decorate an `async` test function with `@coralflow_test` and call `coralflow_main()` under `if __name__ == "__main__":`.

```python
# test_add_kernel.py
from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.coralflow.base_fixture import BaseCoralNPUFixture
from coralnpu_test_utils.coralflow.runner import coralflow_main, coralflow_test
import numpy as np


@coralflow_test
async def test_add_kernel(fixture: BaseCoralNPUFixture):
    # 1. Resolve the ELF path and look up global symbol addresses
    r = runfiles.Create()
    await fixture.load_elf_and_lookup_symbols(
        r.Rlocation("coralnpu_hw/examples/add_kernel.elf"),
        ["in_buf_1", "in_buf_2", "out_buf"],
    )

    # 2. Populate input buffers in DTCM
    in1 = np.arange(8, dtype=np.uint32)
    in2 = np.ones(8, dtype=np.uint32) * 100
    await fixture.write("in_buf_1", in1)
    await fixture.write("in_buf_2", in2)
    await fixture.write("out_buf", np.zeros(8, dtype=np.uint32))

    # 3. Execute the core until it hits mpause
    await fixture.run_to_halt()

    # 4. Read back out_buf and verify against NumPy
    actual = await fixture.read("out_buf", dtype=np.uint32, shape=(8,))
    expected = in1 + in2
    np.testing.assert_array_equal(actual, expected)


if __name__ == "__main__":
    coralflow_main()
```

## 3. Define the Bazel Targets (`BUILD`)

Build a standard (`8KB ITCM / 32KB DTCM`) binary for simulator targets and a `_highmem` (`1024KB ITCM / 1024KB DTCM`) binary for the Nexus FPGA bitstream, then wire them into `coralflow_test`:

```python
# BUILD
load("//rules:coralflow_test.bzl", "coralflow_test")
load("//rules:coralnpu_v2.bzl", "coralnpu_v2_binary")

coralnpu_v2_binary(
    name = "add_kernel",
    srcs = ["add_kernel.cc"],
)

coralnpu_v2_binary(
    name = "add_kernel_highmem",
    srcs = ["add_kernel.cc"],
    dtcm_size_kbytes = 1024,
    itcm_size_kbytes = 1024,
)

coralflow_test(
    name = "test_add_kernel",
    srcs = ["test_add_kernel.py"],
    data = [":add_kernel_highmem.elf"],
    elf = ":add_kernel.elf",
)
```

If your program requires more than 8KB ITCM or 32KB DTCM on all backends, set `itcm_size_kbytes = 1024` and `dtcm_size_kbytes = 1024` directly on `add_kernel` and pass `highmem = True` to both `@coralflow_test(highmem=True)` and `coralflow_test(..., highmem = True)`.

## 4. Run Your Test Across Backends

From the repository root, run the same test across any backend:

1. **Fast Functional Simulator (NPUSim)**:

   ```bash
   bazel test //examples:test_add_kernel_npusim
   ```

2. **Cycle-Accurate Verilator RTL Simulation**:

   ```bash
   bazel test //examples:test_add_kernel_verilator
   ```

   Pass `--test_env=WAVES=1` to record an `.fst` waveform trace in `bazel-testlogs/`.

3. **UVM + Spike Lock-Step Co-Simulation**:

   ```bash
   bazel test //examples:test_add_kernel_uvm
   ```

4. **Physical Nexus FPGA Hardware (Direct via Bazel)**:

   ```bash
   bazel run //examples:test_add_kernel_nexus_fpga -- --usb-serial <usb_serial> --highmem --verify
   ```

5. **Physical Nexus FPGA Hardware (Standalone Lab Tarball without Bazel)**:

   ```bash
   bazel build //examples:test_add_kernel_nexus_fpga_pkg
   scp bazel-bin/examples/test_add_kernel_nexus_fpga_pkg.tar <fpga_host>:/tmp/
   ssh <fpga_host>
   mkdir -p /tmp/add_test && tar -xf /tmp/test_add_kernel_nexus_fpga_pkg.tar -C /tmp/add_test
   cd /tmp/add_test && ./run.sh --usb-serial <usb_serial> --verify
   ```
