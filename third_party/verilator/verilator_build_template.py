# SPDX-License-Identifier: Apache-2.0
# Copyright 2021 the rules_hdl authors
"""A tool for generating Verilator source files required for compilation"""

import argparse
import json
from pathlib import Path
from typing import Dict


def _substitutions_arg(value: str) -> Dict[str, str]:
    return json.loads(value)


def parse_args() -> argparse.Namespace:
    """Parse command line arguments"""
    parser = argparse.ArgumentParser()

    parser.add_argument(
        "--version",
        type=Path,
        required=True,
        help="A file containing the current Verilator version.",
    )

    parser.add_argument(
        "--substitutions",
        type=_substitutions_arg,
        required=True,
        help="Substitutions to apply to the template file.",
    )

    parser.add_argument(
        "--template",
        type=Path,
        required=True,
        help="The template file to be updated.",
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

    version = args.version.read_text(encoding="utf-8").strip()

    content = args.template.read_text(encoding="utf-8")
    for key, value in args.substitutions.items():
        value = value.replace("{VERILATOR_VERSION}", version)
        content = content.replace(key, value)

    args.output.write_text(content, encoding="utf-8")


if __name__ == "__main__":
    main()
