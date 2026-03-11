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

# Lost Trap Reproduction Test
#
# Reproduces the LOST_TRAP bug: two back-to-back vector loads to invalid
# addresses should each cause a trap (trap_count=2), but the missing
# mstatus.MIE/MPIE mechanism allows the second fault to overwrite mepc
# before the first trap handler completes, resulting in trap_count=1.
#
# This file defines main() and is linked with the CRT (coralnpu_v2_binary).
# The CRT provides _start, which calls main(). On return 0, CRT calls mpause.

.balign 4
.global main
.type main, @function

main:
    # Install our custom trap handler (overrides CRT default)
    la   t0, trap_handler
    csrw mtvec, t0

    # Initialize trap_count to 0
    la   t0, trap_count
    sw   zero, 0(t0)

    # Initialize last_mcause/last_mepc/last_mtval to 0
    la   t0, last_mcause
    sw   zero, 0(t0)
    la   t0, last_mepc
    sw   zero, 0(t0)
    la   t0, last_mtval
    sw   zero, 0(t0)

    # Configure vector unit: e32, m1, vl=4
    li   t0, 4
    vsetvli t0, t0, e32, m1, ta, ma

    # Set up both invalid addresses BEFORE either load, so the two
    # vle32.v instructions are truly back-to-back in the pipeline.
    # 0x90000000 and 0x90001000 are outside valid AXI range
    # (0x20000000-0x203FFFFF), so the AXI slave returns SLVERR,
    # causing load access faults (mcause=5).
    lui  a0, 0x90000          # a0 = 0x90000000
    lui  a1, 0x90001          # a1 = 0x90001000

    # Two back-to-back vector loads to invalid addresses.
    # Both will be dispatched into the LSU/vector pipeline and both
    # will generate faults. The bug: the second fault overwrites mepc
    # before the first trap handler runs.
    vle32.v v1, (a0)          # Trap A: load access fault
    vle32.v v2, (a1)          # Trap B: load access fault

    # If we reach here, both traps were handled (or one was lost).
    # Return 0 so CRT calls mpause (halts the core cleanly).
    li   a0, 0
    ret

# Trap handler: counts traps, stores diagnostics, advances mepc past
# the faulting instruction, and returns via mret.
.balign 4
.global trap_handler
.type trap_handler, @function
trap_handler:
    # Save t0 via mscratch (t1 is also clobbered but not live across traps)
    csrw mscratch, t0

    # Increment trap_count
    la   t0, trap_count
    lw   t1, 0(t0)
    addi t1, t1, 1
    sw   t1, 0(t0)

    # Store diagnostic info
    csrr t1, mcause
    la   t0, last_mcause
    sw   t1, 0(t0)

    csrr t1, mepc
    la   t0, last_mepc
    sw   t1, 0(t0)

    csrr t1, mtval
    la   t0, last_mtval
    sw   t1, 0(t0)

    # Advance mepc past the faulting instruction (4 bytes)
    csrr t0, mepc
    addi t0, t0, 4
    csrw mepc, t0

    # Restore t0
    csrr t0, mscratch

    mret

# Data section (placed in DTCM by the linker script)
.section .data
.balign 4

.global trap_count
trap_count:
    .word 0

.global last_mcause
last_mcause:
    .word 0

.global last_mepc
last_mepc:
    .word 0

.global last_mtval
last_mtval:
    .word 0
