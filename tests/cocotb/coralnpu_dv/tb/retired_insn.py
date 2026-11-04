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

from dataclasses import dataclass

from coralnpu_test_utils.dispatch_verifier.disasm import disassemble

_WORD = 0xFFFFFFFF


def unpack_writes(mask: int, data: int, first: int = 0) -> dict[int, int]:
    return {
        j: (data >> (32 * j)) & _WORD
        for j in range(first, 32)
        if (mask >> j) & 1
    }


def _disassemble(inst: int, pc: int) -> str:
    try:
        return disassemble(inst, pc)
    except Exception:
        return "?"


@dataclass
class RetiredInsn:
    order: int
    pc: int
    insn: int
    trap: bool = False
    x_wb: int = 0
    x_wdata: int = 0
    f_wb: int = 0
    f_wdata: int = 0
    v_wb: int = 0

    def x_writes(self) -> dict[int, int]:
        return unpack_writes(self.x_wb, self.x_wdata, first=1)

    def f_writes(self) -> dict[int, int]:
        return unpack_writes(self.f_wb, self.f_wdata)

    def __str__(self) -> str:
        parts = [
            f"#{self.order} pc={self.pc:#06x} insn={self.insn:#010x} "
            f"({_disassemble(self.insn, self.pc)})"
        ]
        if self.trap:
            parts.append("TRAP")
        parts += [f"x{j}={v:#x}" for j, v in self.x_writes().items()]
        parts += [f"f{j}={v:#x}" for j, v in self.f_writes().items()]
        if self.v_wb:
            parts.append(f"v_wb={self.v_wb:#x}")
        return " ".join(parts)
