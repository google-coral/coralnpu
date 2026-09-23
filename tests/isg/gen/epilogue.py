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
"""Epilogue and trap handler generator for CoralNPU ISG tests."""

from typing import List

# isg_trap_save layout (bytes):
#   [0]   spilled x6
#   [4]   spilled x7
#   [8]   trap count
#   [12]  reserved
#   [16+] trap log, TRAP_LOG_ENTRY_SIZE bytes per entry: {mcause, mepc}
TRAP_SAVE_SIZE = 1024
TRAP_LOG_OFFSET = 16
WORD_BYTES = 4
TRAP_LOG_MEPC_OFFSET = TRAP_LOG_OFFSET + WORD_BYTES
TRAP_LOG_ENTRY_SIZE = 8
TRAP_LOG_MAX_ENTRIES = (
    TRAP_SAVE_SIZE - TRAP_LOG_OFFSET
) // TRAP_LOG_ENTRY_SIZE


def generate_epilogue(traps_enabled: bool = False) -> List[str]:
    """Generates test completion, trap handler (if enabled), and data sections."""
    lines: List[str] = [
        "    # === ISG RANDOMIZED PAYLOAD END ===",
        ".global isg_payload_end",
        "isg_payload_end:",
        "",
        "    # Test completion: write PASS (1) to tohost and mpause",
        "    li   x1, 1",
        ".option push",
        ".option norelax",
        "    la   x2, tohost",
        ".option pop",
        "    sw   x1, 0(x2)",
        "    .word 0x08000073 # mpause",
        "1:",
        "    j    1b",
        "",
    ]

    if traps_enabled:
        lines.extend([
            "    # Zero-register-overhead trap handler using mscratch swap",
            ".section .text",
            ".balign 64",
            ".global isg_trap_handler",
            ".type isg_trap_handler, @function",
            "isg_trap_handler:",
            "    csrrw   x5, mscratch, x5        # x5 = &isg_trap_save, mscratch = saved x5",
            "    sw      x6, 0(x5)               # Spill working register x6",
            "    sw      x7, 4(x5)               # Spill working register x7",
            "",
            "    lw      x6, 8(x5)               # x6 = trap count",
            "    addi    x7, x6, 1",
            "    sw      x7, 8(x5)               # Increment trap count",
            f"    li      x7, {TRAP_LOG_MAX_ENTRIES}",
            "    bgeu    x6, x7, 9f              # Log full: count, but do not log",
            "    slli    x6, x6, 3               # x6 = count * TRAP_LOG_ENTRY_SIZE (8)",
            "    add     x6, x6, x5              # x6 = &isg_trap_save + count * 8",
            "    csrr    x7, mcause",
            f"    sw      x7, {TRAP_LOG_OFFSET}(x6)              # Log mcause",
            "    csrr    x7, mepc",
            f"    sw      x7, {TRAP_LOG_MEPC_OFFSET}(x6)              # Log mepc",
            "9:",
            "    csrr    x6, mepc",
            "    addi    x6, x6, 4               # mepc += 4 (skip faulting instruction)",
            "    csrw    mepc, x6",
            "",
            "    lw      x6, 0(x5)               # Restore x6",
            "    lw      x7, 4(x5)               # Restore x7",
            "    csrrw   x5, mscratch, x5        # Restore x5 and reset mscratch pointer",
            "    mret",
            "",
        ])

    # Data sections. tohost is a 64-bit HTIF mailbox in the .htif section that
    # the linker script places in DTCM (same as the semihosting CRT). Writing
    # 1 encodes exit code 0: (code << 1) | 1.
    lines.extend([
        ".section .htif, \"aw\", @progbits",
        ".balign 64",
        ".global tohost",
        "tohost:",
        "    .word 0",
        "    .word 0",
        "",
        ".section .bss",
        ".balign 64",
        ".global isg_scratch",
        "isg_scratch:",
        "    .zero 2048",
        "",
        ".balign 64",
        ".global isg_trap_save",
        "isg_trap_save:",
        f"    .zero {TRAP_SAVE_SIZE}",
        "",
    ])

    return lines
