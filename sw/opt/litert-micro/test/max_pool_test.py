import asyncio
import os
import sys
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.sim_backends.mpact_npusim_test_fixture import MpactNpuSimTestFixture


async def run_test_case(elf_file, input_shape):
    # Symbols to resolve
    symbols = [
        "input_dims",
        "input_data",
        "output_dims",
        "output_data",
        "output_data_ref",
        "params_stride_width",
        "params_stride_height",
        "params_filter_width",
        "params_filter_height",
        "params_padding_width",
        "params_padding_height",
        "params_activation_min",
        "params_activation_max",
        "ref_cycles",
        "opt_cycles",
        "heartbeat",
    ]

    fixture = await MpactNpuSimTestFixture.Create(highmem=True)
    await fixture.load_elf_and_lookup_symbols(elf_file, symbols)

    # Parameters for MaxPool 2x2
    filter_height = 2
    filter_width = 2
    stride_height = 2
    stride_width = 2
    activation_min = -128
    activation_max = 127

    # Calculate output shape (VALID padding)
    out_h = (input_shape[1] - filter_height) // stride_height + 1
    out_w = (input_shape[2] - filter_width) // stride_width + 1
    output_shape = [input_shape[0], out_h, out_w, input_shape[3]]

    # VALID padding means no padding needed if dimensions fit perfectly
    pad_h = 0
    pad_w = 0

    print(
        f"Running simulation for shape {input_shape} -> {output_shape}...",
        flush=True
    )

    # Generate random input data
    input_data = np.random.randint(-128, 127, size=input_shape, dtype=np.int8)

    await fixture.write("input_dims", np.array(input_shape, dtype=np.int32))
    await fixture.write("input_data", input_data)
    await fixture.write("output_dims", np.array(output_shape, dtype=np.int32))

    await fixture.write_word("params_stride_width", stride_width, signed=True)
    await fixture.write_word(
        "params_stride_height", stride_height, signed=True
    )
    await fixture.write_word("params_filter_width", filter_width, signed=True)
    await fixture.write_word(
        "params_filter_height", filter_height, signed=True
    )
    await fixture.write_word("params_padding_width", pad_w, signed=True)
    await fixture.write_word("params_padding_height", pad_h, signed=True)
    await fixture.write_word(
        "params_activation_min", activation_min, signed=True
    )
    await fixture.write_word(
        "params_activation_max", activation_max, signed=True
    )

    # Run Simulation
    await fixture.run_to_halt(timeout_cycles=100_000_000)

    # Read Results
    ref_cycles = int.from_bytes((await fixture.read("ref_cycles",
                                                    8)).tobytes(), "little")
    print(f"  Ref Cycles: {ref_cycles}")

    out_size = int(np.prod(output_shape))
    ref_out = await fixture.read(
        "output_data_ref", dtype=np.int8, shape=(out_size, )
    )

    opt_cycles = int.from_bytes((await fixture.read("opt_cycles",
                                                    8)).tobytes(), "little")
    print(f"  Opt Cycles: {opt_cycles}")

    if opt_cycles > 0:
        print(f"  Speedup: {ref_cycles / opt_cycles:.2f}x")

    opt_out = await fixture.read(
        "output_data", dtype=np.int8, shape=(out_size, )
    )

    # Verify
    mismatches = np.sum(opt_out != ref_out)
    if mismatches > 0:
        print(f"  FAILED: {mismatches} mismatches found!", flush=True)
        sys.exit(1)
    else:
        print("  SUCCESS: Outputs match.", flush=True)


async def run_max_pool_sim_test():
    r = runfiles.Create()
    elf_file = r.Rlocation(
        "coralnpu_hw/sw/opt/litert-micro/test/max_pool_test.elf"
    )

    if not os.path.exists(elf_file):
        raise FileNotFoundError(f"ELF file not found: {elf_file}")

    test_shapes = [
        [1, 100, 100, 16],
        [1, 50, 50, 48],
    ]

    for shape in test_shapes:
        await run_test_case(elf_file, shape)


if __name__ == "__main__":
    asyncio.run(run_max_pool_sim_test())
