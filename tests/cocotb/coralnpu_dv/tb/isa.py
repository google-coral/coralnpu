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

OPCODE_SYSTEM = 0x73

# Zicsr funct3 values: csrrw, csrrs, csrrc, csrrwi, csrrsi, csrrci.
CSR_FUNCT3 = frozenset({1, 2, 3, 5, 6, 7})

COUNTER_CSRS = frozenset({
    0xB00,  # mcycle
    0xB02,  # minstret
    0xB80,  # mcycleh
    0xB82,  # minstreth
    0xC00,  # cycle
    0xC01,  # time
    0xC02,  # instret
    0xC80,  # cycleh
    0xC81,  # timeh
    0xC82,  # instreth
})


def opcode(insn: int) -> int:
    """Bits [6:0]."""
    return insn & 0x7F


def rd(insn: int) -> int:
    """Bits [11:7]: the destination register."""
    return (insn >> 7) & 0x1F


def funct3(insn: int) -> int:
    """Bits [14:12]."""
    return (insn >> 12) & 0x7


def csr_addr(insn: int) -> int:
    """Bits [31:20]: the CSR number of a Zicsr instruction."""
    return (insn >> 20) & 0xFFF


def is_csr_op(insn: int) -> bool:
    """True for the six Zicsr instructions."""
    return opcode(insn) == OPCODE_SYSTEM and funct3(insn) in CSR_FUNCT3


def is_counter_access(
    insn: int, counters: frozenset[int] = COUNTER_CSRS
) -> bool:
    """True if `insn` is a Zicsr instruction on one of `counters`."""
    return is_csr_op(insn) and csr_addr(insn) in counters