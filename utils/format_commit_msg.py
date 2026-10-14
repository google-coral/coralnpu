#!/usr/bin/env python3
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
"""Reflows or checks git commit message bodies at 70 columns."""

import argparse
import re
import sys
import textwrap

MAX_BODY_WIDTH = 70
BULLET_RE = re.compile(r"^(\s*(?:[-*+]|\d+[.)])\s+)")
# Known single-word trailers plus any hyphenated trailer key (e.g. Change-Id:,
# Signed-off-by:, Depends-On:, PiperOrigin-RevId:, GitOrigin-RevId:).
TRAILER_RE = re.compile(
    r"^(?:[A-Za-z0-9]+-[A-Za-z0-9-]+|"
    r"Bug|Fix(?:es|ed)?|Closes|Test|Cc):\s",
    re.IGNORECASE,
)
GENERIC_KEY_VALUE_RE = re.compile(r"^[A-Za-z0-9-]+:\s")


def find_footer_lines(lines: list[str]) -> set[int]:
    """Returns line indices belonging to a trailing footer/trailer block."""
    end = len(lines) - 1
    while end >= 1 and (lines[end].strip() == ""
                        or lines[end].startswith("#")):
        end -= 1
    if end < 1:
        return set()

    start = end
    while start >= 1 and lines[start].strip() != "":
        start -= 1
    footer_range = range(start + 1, end + 1)
    non_comment = [i for i in footer_range if not lines[i].startswith("#")]
    if not non_comment:
        return set()

    # If the last paragraph contains at least one recognized trailer and all
    # lines in it are Key: Value pairs, treat every line in it as a trailer.
    if any(TRAILER_RE.match(lines[i])
           for i in non_comment) and all(GENERIC_KEY_VALUE_RE.match(lines[i])
                                         for i in non_comment):
        return set(non_comment)
    return set()


def is_fixed_line(line: str, idx: int, footer_indices: set[int]) -> bool:
    stripped = line.strip()
    return (
        stripped == "" or line.startswith("#") or idx in footer_indices
        or bool(TRAILER_RE.match(line))
    )


def format_commit_message(text: str, reflow_short_lines: bool = True) -> str:
    lines = text.splitlines()
    if not lines or re.match(r"^(Merge|Revert)\s", lines[0]):
        return text

    footer_indices = find_footer_lines(lines)
    out = [lines[0]]
    idx = 1
    n = len(lines)
    in_fence = False

    while idx < n:
        line = lines[idx]

        if line.strip().startswith("```"):
            in_fence = not in_fence
            out.append(line)
            idx += 1
            continue

        if in_fence or is_fixed_line(line, idx, footer_indices):
            out.append(line)
            idx += 1
            continue

        bullet_match = BULLET_RE.match(line)
        if bullet_match:
            prefix = bullet_match.group(1)
            sub_indent = " " * len(prefix)
            block = [line]
            idx += 1
            while idx < n:
                nxt = lines[idx]
                if (nxt.strip().startswith("```")
                        or is_fixed_line(nxt, idx, footer_indices)
                        or BULLET_RE.match(nxt)):
                    break
                nxt_indent = len(nxt) - len(nxt.lstrip(" "))
                if nxt_indent >= len(sub_indent):
                    block.append(nxt)
                    idx += 1
                else:
                    break

            should_wrap = ((len(block) > 1 or len(block[0]) > MAX_BODY_WIDTH)
                           if reflow_short_lines else
                           any(len(b) > MAX_BODY_WIDTH for b in block))
            if not should_wrap:
                out.extend(block)
            else:
                first_body = block[0][len(prefix):].strip()
                rest_body = [b.strip() for b in block[1:]]
                combined = " ".join([first_body] + rest_body)
                out.append(
                    textwrap.fill(
                        combined,
                        width=MAX_BODY_WIDTH,
                        initial_indent=prefix,
                        subsequent_indent=sub_indent,
                        break_long_words=False,
                        break_on_hyphens=False,
                    )
                )
        else:
            indent_match = re.match(r"^(\s*)", line)
            indent = indent_match.group(1) if indent_match else ""
            block = [line]
            idx += 1
            if not line.rstrip().endswith(":"):
                while idx < n:
                    nxt = lines[idx]
                    if (nxt.strip().startswith("```")
                            or is_fixed_line(nxt, idx, footer_indices)
                            or BULLET_RE.match(nxt)):
                        break
                    nxt_indent_match = re.match(r"^(\s*)", nxt)
                    nxt_indent = (
                        nxt_indent_match.group(1) if nxt_indent_match else ""
                    )
                    if nxt_indent == indent:
                        block.append(nxt)
                        idx += 1
                        if nxt.rstrip().endswith(":"):
                            break
                    else:
                        break

            should_wrap = ((len(block) > 1 or len(block[0]) > MAX_BODY_WIDTH)
                           if reflow_short_lines else
                           any(len(b) > MAX_BODY_WIDTH for b in block))
            if not should_wrap:
                out.extend(block)
            else:
                combined = " ".join(b.strip() for b in block)
                out.append(
                    textwrap.fill(
                        combined,
                        width=MAX_BODY_WIDTH,
                        initial_indent=indent,
                        subsequent_indent=indent,
                        break_long_words=False,
                        break_on_hyphens=False,
                    )
                )

    trailing_newline = "\n" if text.endswith("\n") else ""
    return "\n".join(out) + trailing_newline


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Format or check git commit message body at 70 columns."
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit non-zero if any wrappable body line exceeds 70 chars.",
    )
    parser.add_argument("msg_file", help="Path to the commit message file.")
    args = parser.parse_args()

    with open(args.msg_file, "r", encoding="utf-8") as f:
        original = f.read()

    if args.check:
        checked = format_commit_message(original, reflow_short_lines=False)
        return 1 if checked != original else 0

    formatted = format_commit_message(original, reflow_short_lines=True)
    if formatted != original:
        with open(args.msg_file, "w", encoding="utf-8") as f:
            f.write(formatted)
    return 0


if __name__ == "__main__":
    sys.exit(main())
