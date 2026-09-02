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
"""Dynamic in-place terminal UI for per-case instruction dispatch monitoring."""

from __future__ import annotations

import os
import sys
import time
from typing import Any

from coralnpu_test_utils.dispatch_verifier.monitor import DispatchedInst


class TerminalUI:
    """Renders instructions for the active testcase and progress bar in-place."""

    def __init__(
        self,
        max_lines: int = 10,
        pbar: Any = None,
        stream: Any = None,
    ):
        self.max_lines = max_lines
        self.pbar = pbar
        self.stream = stream if stream is not None else sys.stderr
        # Enabled by default unless explicitly disabled via DISPATCH_UI=0
        self.enabled = os.environ.get("DISPATCH_UI", "1").lower() not in (
            "0",
            "false",
            "no",
        )
        self.case_name: str = "Initialization"
        self._case_insts: list[DispatchedInst] = []
        self._rendered = False
        self._last_rendered_lines = 0
        self._last_draw_time = 0.0

    def set_pbar(self, pbar: Any) -> None:
        """Attaches a tqdm progress bar instance."""
        self.pbar = pbar

    def start_case(self, case_name: str) -> None:
        """Starts tracking instructions for a new testcase, resetting the display."""
        self.case_name = case_name
        self._case_insts.clear()
        self.render(force=True)

    def add_instruction(self, inst: DispatchedInst) -> None:
        """Records an instruction into the active case buffer."""
        self._case_insts.append(inst)

    def render(self, force: bool = False) -> None:
        """Redraws the active case's instruction window in-place."""
        if not self.enabled:
            return

        now = time.time()
        # Throttle redraws to at most ~30 FPS (0.033s) to prevent terminal flicker
        if not force and (now - self._last_draw_time < 0.033):
            return
        self._last_draw_time = now

        box_width = 108
        inner_width = box_width - 2

        # Select instructions to display for this case
        if len(self._case_insts) > self.max_lines:
            display_insts = self._case_insts[-self.max_lines:]
            shown_info = f" (showing last {self.max_lines}/{len(self._case_insts)})"
        else:
            display_insts = self._case_insts
            shown_info = f" ({len(self._case_insts)} insts)"

        header_title = f" Case: {self.case_name}{shown_info} "
        if len(header_title) > inner_width - 2:
            header_title = header_title[:inner_width - 5] + "... "

        lines: list[str] = []
        lines.append(
            "┌─" + header_title + "─" * (inner_width - len(header_title) - 1) +
            "┐"
        )

        if not display_insts:
            placeholder = " ... executing case ...".ljust(inner_width)
            lines.append(f"│{placeholder}│")
        else:
            for inst in display_insts:
                content = (
                    f" [Cycle: {inst.cycle:5d}] Lane {inst.lane}: "
                    f"addr: 0x{inst.pc:08x} | {inst.disasm:<30} | "
                    f"Target: {inst.fu.name:<5} | (0x{inst.raw_inst:08x})"
                )
                if len(content) > inner_width:
                    content = content[:inner_width - 3] + "..."
                else:
                    content = content.ljust(inner_width)
                lines.append(f"│{content}│")

        lines.append("└" + "─" * inner_width + "┘")

        out: list[str] = []
        total_box_lines = len(lines)

        # Move cursor up and clear previous block
        if self._rendered and self._last_rendered_lines > 0:
            out.append(f"\033[{self._last_rendered_lines}A\r\033[J")

        for line in lines:
            out.append(f"\033[2K{line}\n")

        # If pbar is attached, update the progress bar line below the box
        if self.pbar is not None:
            pbar_str = str(self.pbar)
            out.append(f"\033[2K{pbar_str}\r")

        self.stream.write("".join(out))
        self.stream.flush()
        self._rendered = True
        self._last_rendered_lines = total_box_lines

    def finish(self) -> None:
        """Finalizes the display and moves cursor past the UI block."""
        if self._rendered and self.enabled:
            self.render(force=True)
            self.stream.write("\n")
            self.stream.flush()
            self._rendered = False
            self._last_rendered_lines = 0
