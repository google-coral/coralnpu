# Copyright 2026 Google LLC
import asyncio
import os
import sys
import numpy as np
from bazel_tools.tools.python.runfiles import runfiles
from coralnpu_test_utils.sim_backends.mpact_npusim_test_fixture import MpactNpuSimTestFixture


async def run_test_case(
    elf_file, input_shape, filter_shape, stride, padding_type="VALID"
):
    # Symbols to resolve
    symbols = [
        "input_dims",
        "input_data",
        "filter_dims",
        "filter_data",
        "bias_dims",
        "bias_data",
        "output_dims",
        "output_data",
        "output_data_ref",
        "params_stride_width",
        "params_stride_height",
        "params_padding_width",
        "params_padding_height",
        "params_input_offset",
        "params_output_offset",
        "params_activation_min",
        "params_activation_max",
        "per_channel_multiplier",
        "per_channel_shift",
        "ref_cycles",
        "opt_cycles",
        "heartbeat",
    ]

    fixture = await MpactNpuSimTestFixture.Create(highmem=True)
    await fixture.load_elf_and_lookup_symbols(elf_file, symbols)

    # Parameters
    filter_height = filter_shape[1]
    filter_width = filter_shape[2]
    output_depth = filter_shape[0]
    stride_height, stride_width = stride

    input_offset = 128
    output_offset = -128
    activation_min = -128
    activation_max = 127

    if padding_type == "SAME":
        out_h = (input_shape[1] + stride_height - 1) // stride_height
        out_w = (input_shape[2] + stride_width - 1) // stride_width
        pad_h = (
            max(
                0, (out_h - 1) * stride_height + filter_height - input_shape[1]
            ) // 2
        )
        pad_w = max(
            0, (out_w - 1) * stride_width + filter_width - input_shape[2]
        ) // 2
    else:  # VALID
        out_h = (input_shape[1] - filter_height) // stride_height + 1
        out_w = (input_shape[2] - filter_width) // stride_width + 1
        pad_h = 0
        pad_w = 0

    output_shape = [input_shape[0], out_h, out_w, output_depth]

    print(
        f"Testing: Input {input_shape}, Filter {filter_shape}, Stride {stride}, Padding {padding_type} -> Output {output_shape}",
        flush=True,
    )

    # Generate random data
    input_data = np.random.randint(-128, 127, size=input_shape, dtype=np.int8)
    filter_data = np.random.randint(
        -128, 127, size=filter_shape, dtype=np.int8
    )
    bias_data = np.random.randint(
        -1000, 1000, size=(output_depth, ), dtype=np.int32
    )
    per_channel_multiplier = np.random.randint(
        1073741824, 2147483647, size=(output_depth, ), dtype=np.int32
    )
    per_channel_shift = np.random.randint(
        -10, -1, size=(output_depth, ), dtype=np.int32
    )

    await fixture.write("input_dims", np.array(input_shape, dtype=np.int32))
    await fixture.write("input_data", input_data)
    await fixture.write("filter_dims", np.array(filter_shape, dtype=np.int32))
    await fixture.write("filter_data", filter_data)
    await fixture.write("bias_dims", np.array([output_depth], dtype=np.int32))
    await fixture.write("bias_data", bias_data)
    await fixture.write("output_dims", np.array(output_shape, dtype=np.int32))

    await fixture.write_word("params_stride_width", stride_width, signed=True)
    await fixture.write_word(
        "params_stride_height", stride_height, signed=True
    )
    await fixture.write_word("params_padding_width", pad_w, signed=True)
    await fixture.write_word("params_padding_height", pad_h, signed=True)
    await fixture.write_word("params_input_offset", input_offset, signed=True)
    await fixture.write_word(
        "params_output_offset", output_offset, signed=True
    )
    await fixture.write_word(
        "params_activation_min", activation_min, signed=True
    )
    await fixture.write_word(
        "params_activation_max", activation_max, signed=True
    )
    await fixture.write("per_channel_multiplier", per_channel_multiplier)
    await fixture.write("per_channel_shift", per_channel_shift)

    # Run Simulation
    await fixture.run_to_halt(timeout_cycles=500_000_000)

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
        idx = np.where(opt_out != ref_out)[0][0]
        print(
            f"  First mismatch at index {idx}: Opt {opt_out[idx]}, Ref {ref_out[idx]}"
        )
        sys.exit(1)
    else:
        print("  SUCCESS: Outputs match.", flush=True)


async def run_conv_sim_test():
    r = runfiles.Create()
    elf_file = r.Rlocation(
        "coralnpu_hw/sw/opt/litert-micro/test/conv_test.elf"
    )

    if not os.path.exists(elf_file):
        raise FileNotFoundError(f"ELF file not found: {elf_file}")

    test_cases = [
        # 1. Conv_4_4_16_StrideN (ic <= 16)
        {
            "input": [1, 10, 10, 16],
            "filter": [16, 4, 4, 16],
            "stride": (1, 1)
        },
        {
            "input": [1, 10, 10, 16],
            "filter": [16, 4, 4, 16],
            "stride": (2, 2)
        },
        {
            "input": [1, 10, 10, 16],
            "filter": [48, 4, 4, 16],
            "stride": (1, 1)
        },
        # 2. Conv_4_4_48_Stride1 (ic <= 48, stride 1)
        {
            "input": [1, 10, 10, 48],
            "filter": [16, 4, 4, 48],
            "stride": (1, 1)
        },
        # 3. Conv_48_4_4_48 (ic=48, oc=48)
        {
            "input": [1, 10, 10, 48],
            "filter": [48, 4, 4, 48],
            "stride": (1, 1)
        },
        {
            "input": [1, 10, 10, 48],
            "filter": [48, 4, 4, 48],
            "stride": (2, 2)
        },
        # 4. Conv2D_4x4 (Generic 4x4)
        {
            "input": [1, 8, 8, 32],
            "filter": [32, 4, 4, 32],
            "stride": (1, 1)
        },
        {
            "input": [1, 8, 8, 16],
            "filter": [48, 4, 4, 16],
            "stride": (1, 1)
        },
        # 5. Fallback (fh=3, fw=3)
        {
            "input": [1, 8, 8, 16],
            "filter": [16, 3, 3, 16],
            "stride": (1, 1)
        },
    ]

    for tc in test_cases:
        await run_test_case(elf_file, tc["input"], tc["filter"], tc["stride"])


if __name__ == "__main__":
    asyncio.run(run_conv_sim_test())
