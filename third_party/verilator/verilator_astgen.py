# SPDX-License-Identifier: Apache-2.0
# Copyright 2021 the rules_hdl authors
"""A process wrapper for running Verilator's astgen tool in a Bazel action."""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    """Parse command line arguments"""
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--src",
        dest="srcs",
        type=Path,
        action="append",
        required=True,
        help="Sources that need to appear in include paths.",
    )

    parser.add_argument(
        "--out",
        dest="outputs",
        type=Path,
        action="append",
        required=True,
        help="The expected output files.",
    )

    parser.add_argument(
        "--astgen",
        type=Path,
        required=True,
        help="The path to the astgen tool."
    )

    parser.add_argument(
        "astgen_args",
        nargs="*",
        help="Remaining args to forward to astgen.",
    )

    return parser.parse_args()


def main() -> None:
    """The main entrypoint"""
    args = parse_args()

    includes = []
    for parent in sorted(set(path.parent for path in args.srcs)):
        includes.extend(["-I", str(parent)])

    result = subprocess.run(
        [sys.executable, str(args.astgen)] + includes + args.astgen_args,
        check=False,
        stderr=subprocess.STDOUT,
        stdout=subprocess.PIPE,
        encoding="utf-8",
    )

    if result.returncode:
        print(result.args, file=sys.stderr)
        print(result.stdout, file=sys.stderr)
        sys.exit(result.returncode)

    for out in args.outputs:
        if out.resolve() != Path(out.name).resolve():
            shutil.copyfile(out.name, out)


if __name__ == "__main__":
    main()
