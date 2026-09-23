# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Command-line runner for Constrained-Random Instruction Stream Generation (ISG)."""

import argparse

from tests.isg.gen.program import (
    DEFAULT_BATCH_SIZE,
    DEFAULT_PROGRAM_LENGTH,
    generate_program,
)


def main() -> None:
    """Parses command-line flags and generates an ISG assembly file."""
    parser = argparse.ArgumentParser(
        description="CoralNPU Constrained-Random Instruction Stream Generator"
    )
    parser.add_argument(
        "--alphabet", required=True, help="Path to alphabet JSON file"
    )
    parser.add_argument(
        "--seed",
        default=None,
        help=(
            "PRNG seed (integer, string, or 'random'). If omitted or "
            "'random', a fresh random seed is generated."
        ),
    )
    parser.add_argument(
        "--batch-index",
        type=int,
        default=0,
        help="Index of this program within batch (0..batch-size-1)",
    )
    parser.add_argument(
        "--batch-size",
        type=int,
        default=DEFAULT_BATCH_SIZE,
        help="Total number of programs in batch for dealt partitioning",
    )
    parser.add_argument(
        "--length",
        type=int,
        default=DEFAULT_PROGRAM_LENGTH,
        help=(
            "Minimum number of opcode slots in the payload. The payload can "
            "be longer: jalr expands to two instructions, and the dealt "
            "cover is always emitted in full."
        ),
    )
    parser.add_argument(
        "--trap-rate",
        type=float,
        default=0.0,
        help="Probability of injecting controlled traps (undef/ecall)",
    )
    parser.add_argument(
        "--align-mode",
        choices=["natural", "unaligned", "straddle"],
        default="natural",
        help="Memory offset alignment mode",
    )
    parser.add_argument(
        "--output", required=True, help="Output .S assembly file path"
    )

    args = parser.parse_args()

    full_assembly = generate_program(
        alphabet_path=args.alphabet,
        seed=args.seed,
        batch_index=args.batch_index,
        batch_size=args.batch_size,
        length=args.length,
        trap_rate=args.trap_rate,
        align_mode=args.align_mode,
    )

    with open(args.output, "w", encoding="utf-8") as f:
        for line in full_assembly:
            f.write(f"{line}\n")


if __name__ == "__main__":
    main()
