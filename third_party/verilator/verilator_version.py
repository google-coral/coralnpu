# SPDX-License-Identifier: Apache-2.0
# Copyright 2021 the rules_hdl authors
"""A tool for parsing the current Verilator version from a Verilator change log."""

import argparse
import re
from pathlib import Path


def parse_args() -> argparse.Namespace:
    """Parse command line arguments"""
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--changelog",
        type=Path,
        required=True,
        help="The path to the verilator changelog.",
    )

    parser.add_argument(
        "--output",
        type=Path,
        required=True,
        help="The expected output files.",
    )

    return parser.parse_args()


def main() -> None:
    """The main entrypoint"""
    args = parse_args()

    version = None
    for line in args.changelog.read_text(encoding="utf-8").splitlines():
        match = re.match(
            r"^Verilator ([\d\.]+) \d\d\d\d-\d\d-\d\d",
            line,
        )
        if match:
            version = match.group(1)
            break

    if not version:
        raise ValueError(
            f"Could not detect verilator version from changelog: {args.changelog}"
        )

    args.output.write_text(version, encoding="utf-8")


if __name__ == "__main__":
    main()
