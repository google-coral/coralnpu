# NPUSim MobileNet Tutorial

This tutorial explains the plumbing and mechanics of how `npusim_run_mobilenet.py` executes and interacts with the compiled C++ binary `run_full_mobilenet_v1.cc` using the CoralNPU Python simulator bindings.

## Overview

Simulating a TFLite Micro model like MobileNet typically requires two components:

1. **Host Python Script (`npusim_run_mobilenet.py`)**: Controls the NPU simulator, injects inputs, running the simulation, and extracting outputs.
2. **Device C++ Binary (`run_full_mobilenet_v1.cc`)**: The C++ code sets up the TFLM interpreter to run inference. Building the target with the `coralnpu_v2_binary` Bazel rule packages it to run as an executable on the simulated CoralNPU.

## 1. The C++ Device Code (`run_full_mobilenet_v1.cc`)

The C++ code is responsible for the actual inference pipeline. To communicate with the Python host, it exposes specific memory buffers as global variables.

### Memory Sections and Symbols

We define global arrays placed in specific memory sections (`.data` and `.extdata`) using GCC `__attribute__` pragmas:

```cpp
extern "C" {
// The tensor arena for TFLite Micro working memory
constexpr size_t kTensorArenaSize = 4 * 1024 * 1024; // 4MB
uint8_t tensor_arena[kTensorArenaSize] __attribute__((section(".extdata"), aligned(16)));

// Buffers the Python script will read/write
int8_t inference_status = -1;
uint8_t inference_input[224 * 224 * 3] __attribute__((section(".data"), aligned(16)));
int8_t inference_output[5] __attribute__((section(".data"), aligned(16)));
}
```

By placing these inside `extern "C"`, we prevent C++ name mangling, allowing the Python script to easily look up their addresses in the compiled ELF binary by name (e.g., `"inference_input"`).

### Inference Execution

Inside `main()`, the script uses `memcpy` to bridge the exposed symbols and the internal TFLM interpreter tensors:

1. **Input**: `memcpy` copies data from `inference_input` (which Python populated) into the TFLM input tensor.
2. **Invoke**: The interpreter runs the model.
3. **Output**: `memcpy` copies data from the TFLM output tensor to `inference_output` (where Python will read it).

> [!NOTE]
> `printf` is supported by semihosting via HTIF (Host Target Interface), which adds some overhead and impacts performance during simulation. It's recommended to limit outputs during full performance profiling.

## 2. The Python Host Script (`npusim_run_mobilenet.py`)

The Python script uses CoralFlow (`@coralflow_test` and `coralflow_main`) to instantiate the target fixture, load the ELF binary, and interact with the C++ symbols in memory.

### Fixture Decorator, ELF Loading, and Symbol Resolution

```python
@coralflow_test(highmem=True)
async def run_full_mobilenet(fixture):
    r = runfiles.Create()
    symbols = await fixture.load_elf_and_lookup_symbols(
        r.Rlocation(
            "coralnpu_hw/tests/npusim_examples/run_full_mobilenet_v1_binary.elf"
        ),
        symbols=["inference_status", "inference_input", "inference_output"],
        optional=True,
    )
```

`load_elf_and_lookup_symbols` resolves the `.elf` binary path, loads the program into the simulator, and returns a dictionary (`symbols`) mapping symbol names like `"inference_input"` to their 32-bit RISC-V memory addresses.

### Injecting Inputs

Before running the simulation, the script populates the input buffer:

```python
if "inference_input" in symbols:
    input_data = np.random.randint(
        -128, 127, size=(224 * 224 * 3,), dtype=np.int8
    )
    await fixture.write("inference_input", input_data)
```

This directly writes the bytes into the `inference_input` symbol in the target's memory space.

### Execution and Extraction

```python
await fixture.run_to_halt()
```

The simulator runs until the C++ application exits or hits `ebreak`.

Once complete, the host script reads the output array and status directly from memory:

```python
if "inference_output" in symbols:
    output_data = await fixture.read(
        "inference_output", size=5, dtype=np.int8, shape=(5,)
    )

if "inference_status" in symbols:
    inference_status = int(
        (await fixture.read("inference_status", size=1, dtype=np.int8))[0]
    )
    assert inference_status == 0, (
        f"MobileNet inference failed with status {inference_status}"
    )
```

Finally, `fixture.read` verifies that `inference_status == 0` to confirm execution succeeded.

## How to Run

To run the simulation on NPUSim or on Nexus FPGA hardware from the repository root:

```bash
# Run on NPUSim (functional simulator):
bazel test //tests/npusim_examples:npusim_run_mobilenet_npusim

# Or via the convenience alias:
bazel run //tests/npusim_examples:npusim_run_mobilenet

# Run on Nexus FPGA hardware:
bazel run //tests/npusim_examples:npusim_run_mobilenet_nexus_fpga -- --usb-serial <device> --highmem --verify
```

## Summary of the Plumbing Flow

1. **Compile**: `run_full_mobilenet_v1.cc` yields an `.elf` file containing non-mangled symbols at static memory addresses.
2. **Locate**: Python `npusim` parses the `.elf` to find the exact addresses of `inference_input` and `inference_output`.
3. **Write**: Python writes mock input data into the `inference_input` address pointer.
4. **Run**: Python invokes the simulator. The C++ code copies `inference_input` to the model, calculates, and copies results to `inference_output`.
5. **Read**: Simulation finishes. Python reaches into the `inference_output` address pointer to verify the results.
