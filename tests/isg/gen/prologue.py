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
"""Prologue generator for CoralNPU ISG tests."""

from typing import List

from tests.isg.gen.constraints import DATA_BASE_REG

NUM_FPRS = 32
NUM_GPRS = 32


def generate_prologue(
    traps_enabled: bool = False,
    base_reg: int = DATA_BASE_REG,
) -> List[str]:
    """Generates architectural state normalization and base setup prologue."""
    lines: List[str] = [
        ".section .text",
        ".balign 4",
        ".global _start",
        ".type _start, @function",
        "_start:",
        "    # Zero .bss (isg_scratch, isg_trap_save). This _start overrides the",
        "    # CRT's weak _start, so nothing else clears it; without this, RTL TCM",
        "    # contents and ISS zero-initialized memory could disagree on loads.",
        "    # __bss_start__ is 16-byte aligned by the linker script. Words are",
        "    # cleared up to the word-aligned end, then any byte tail.",
        ".option push",
        ".option norelax",
        "    la   x1, __bss_start__",
        "    la   x2, __bss_end__",
        ".option pop",
        "    andi x3, x2, -4",
        "    bgeu x1, x3, 2f",
        "1:",
        "    sw   x0, 0(x1)",
        "    addi x1, x1, 4",
        "    bltu x1, x3, 1b",
        "2:",
        "    bgeu x1, x2, 4f",
        "3:",
        "    sb   x0, 0(x1)",
        "    addi x1, x1, 1",
        "    bltu x1, x2, 3b",
        "4:",
        "",
        f"    # Architectural GPR normalization (zero x1..x31 except x{base_reg})",
    ]

    for reg in range(1, NUM_GPRS):
        if reg != base_reg:
            lines.append(f"    li   x{reg}, 0")

    lines.append("")
    lines.append("    # Enable FPU (FS=01) in mstatus")
    lines.append("    li   x1, 0x00002000")
    lines.append("    csrs mstatus, x1")
    lines.append("")
    lines.append("    # FPR normalization (zero f0..f31 and clear fcsr)")
    for freg in range(NUM_FPRS):
        lines.append(f"    fmv.w.x f{freg}, x0")
    lines.append("    csrw fcsr, x0")
    lines.append("    li   x1, 0")

    if traps_enabled:
        lines.append("")
        lines.append("    # Trap vector and mscratch save area initialization")
        lines.append(".option push")
        lines.append(".option norelax")
        lines.append("    la   x5, isg_trap_handler")
        lines.append("    csrw mtvec, x5")
        lines.append("    la   x5, isg_trap_save")
        lines.append("    csrw mscratch, x5")
        lines.append(".option pop")
        lines.append("    li   x5, 0")

    lines.extend([
        "",
        f"    # Materialize scratchpad buffer base address into x{base_reg}",
        ".global isg_base_reg",
        f".set isg_base_reg, {base_reg}",
        ".option push",
        ".option norelax",
        f"    la   x{base_reg}, isg_scratch",
        ".option pop",
        "",
        ".global isg_payload_start",
        "isg_payload_start:",
        "    # === ISG RANDOMIZED PAYLOAD START ===",
    ])
    return lines
