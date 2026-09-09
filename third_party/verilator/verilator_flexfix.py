# SPDX-License-Identifier: Apache-2.0
# Copyright 2021 the rules_hdl authors
"""A process wrapper for running Verilator's flexfix tool in a Bazel action."""

import argparse
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    """Parse command line arguments"""
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--flexfix",
        type=Path,
        required=True,
        help="The path to `flexfix`.",
    )

    parser.add_argument(
        "--src",
        type=Path,
        required=True,
        help="The input source file to pass to `flexfix`",
    )

    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="The path to the output file the action must produce.",
    )

    parser.add_argument(
        dest="flexfix_args",
        nargs="*",
        help="Additional args to be passed to `flexfix`.",
    )

    return parser.parse_args()


def main() -> None:
    """The main entrypoint"""
    args = parse_args()

    with args.src.open() as handle:
        result = subprocess.run(
            [sys.executable, args.flexfix] + args.flexfix_args,
            stdin=handle,
            check=False,
            stderr=subprocess.STDOUT,
            stdout=subprocess.PIPE,
            encoding="utf-8",
        )

        if result.returncode:
            print(result.stdout, file=sys.stderr)
            sys.exit(result.returncode)

    args.output.write_text(result.stdout, encoding="utf-8")


if __name__ == "__main__":
    main()
