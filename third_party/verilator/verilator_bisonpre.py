# SPDX-License-Identifier: Apache-2.0
# Copyright 2021 the rules_hdl authors
"""A wrapper for bisonpre that reduces noise in console logs."""

import subprocess
import sys


def main() -> None:
    """The main entrypoint"""
    result = subprocess.run(
        [sys.executable] + sys.argv[1:],
        check=False,
        stderr=subprocess.STDOUT,
        stdout=subprocess.PIPE,
        encoding="utf-8",
    )
    # Only log if the process has failed.
    if result.returncode:
        print(result.stdout, file=sys.stderr)
        sys.exit(result.returncode)


if __name__ == "__main__":
    main()
