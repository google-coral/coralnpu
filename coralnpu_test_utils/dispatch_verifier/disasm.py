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
"""Lightweight RISC-V (RV32IMFV) instruction disassembler for DispatchMonitor.

TODO(bilalkhan): Replace this hand-rolled disassembler with `riscv-opcodes` or
another third-party Python disassembly library (e.g., `capstone`) instead of
maintaining custom opcode tables.
"""

# TODO(bilalkhan): Integrate `riscv-opcodes` or another Python disassembly
# library rather than rolling our own instruction decoder.
ABI_NAMES = [
    "zero",
    "ra",
    "sp",
    "gp",
    "tp",
    "t0",
    "t1",
    "t2",
    "s0",
    "s1",
    "a0",
    "a1",
    "a2",
    "a3",
    "a4",
    "a5",
    "a6",
    "a7",
    "s2",
    "s3",
    "s4",
    "s5",
    "s6",
    "s7",
    "s8",
    "s9",
    "s10",
    "s11",
    "t3",
    "t4",
    "t5",
    "t6",
]


def reg_name(reg: int, use_abi: bool = True) -> str:
    if 0 <= reg < 32:
        return ABI_NAMES[reg] if use_abi else f"x{reg}"
    return f"x{reg}"


def vreg_name(reg: int) -> str:
    return f"v{reg}"


def sign_extend(val: int, bits: int) -> int:
    sign_bit = 1 << (bits - 1)
    return (val & (sign_bit - 1)) - (val & sign_bit)


def disassemble(inst: int, pc: int = 0, use_abi: bool = True) -> str:
    """Disassembles a 32-bit RISC-V / RVV instruction into a formatted string."""
    if inst == 0x00000013:
        return "nop"
    if inst == 0x00008067:
        return "ret"
    if inst == 0x10500073:
        return "wfi"
    if inst == 0x00000073:
        return "ecall"
    if inst == 0x00100073:
        return "ebreak"

    opcode = inst & 0x7F
    rd = (inst >> 7) & 0x1F
    funct3 = (inst >> 12) & 0x7
    rs1 = (inst >> 15) & 0x1F
    rs2 = (inst >> 20) & 0x1F
    funct7 = (inst >> 25) & 0x7F

    rd_s = reg_name(rd, use_abi)
    rs1_s = reg_name(rs1, use_abi)
    rs2_s = reg_name(rs2, use_abi)

    # 1. LUI, AUIPC, JAL, JALR
    if opcode == 0x37:  # LUI
        imm = (inst >> 12) & 0xFFFFF
        return f"lui {rd_s}, 0x{imm:x}"

    if opcode == 0x17:  # AUIPC
        imm = (inst >> 12) & 0xFFFFF
        target = (pc + (imm << 12)) & 0xFFFFFFFF
        return f"auipc {rd_s}, 0x{imm:x} # 0x{target:08x}"

    if opcode == 0x6F:  # JAL
        imm20 = (inst >> 31) & 0x1
        imm10_1 = (inst >> 21) & 0x3FF
        imm11 = (inst >> 20) & 0x1
        imm19_12 = (inst >> 12) & 0xFF
        raw_imm = (imm20 << 20) | (imm19_12 << 12) | (imm11 << 11) | (
            imm10_1 << 1
        )
        imm = sign_extend(raw_imm, 21)
        target = (pc + imm) & 0xFFFFFFFF
        if rd == 0:
            return f"j 0x{target:08x}"
        return f"jal {rd_s}, 0x{target:08x}"

    if opcode == 0x67:  # JALR
        imm = sign_extend((inst >> 20) & 0xFFF, 12)
        if rd == 0 and rs1 == 1 and imm == 0:
            return "ret"
        return f"jalr {rd_s}, {imm}({rs1_s})"

    # 2. Branches
    if opcode == 0x63:
        b_imm = (((inst >> 31) & 0x1) << 12
                 | ((inst >> 7) & 0x1) << 11
                 | ((inst >> 25) & 0x3F) << 5
                 | ((inst >> 8) & 0xF) << 1)
        imm = sign_extend(b_imm, 13)
        target = (pc + imm) & 0xFFFFFFFF
        b_map = {
            0x0: "beq",
            0x1: "bne",
            0x4: "blt",
            0x5: "bge",
            0x6: "bltu",
            0x7: "bgeu",
        }
        name = b_map.get(funct3, "b???")
        if rs2 == 0 and name == "beq":
            return f"beqz {rs1_s}, 0x{target:08x}"
        if rs2 == 0 and name == "bne":
            return f"bnez {rs1_s}, 0x{target:08x}"
        return f"{name} {rs1_s}, {rs2_s}, 0x{target:08x}"

    # 3. Loads & Stores
    if opcode == 0x03:
        imm = sign_extend((inst >> 20) & 0xFFF, 12)
        l_map = {0x0: "lb", 0x1: "lh", 0x2: "lw", 0x4: "lbu", 0x5: "lhu"}
        name = l_map.get(funct3, "l???")
        return f"{name} {rd_s}, {imm}({rs1_s})"

    if opcode == 0x23:
        s_imm = ((inst >> 25) & 0x7F) << 5 | ((inst >> 7) & 0x1F)
        imm = sign_extend(s_imm, 12)
        s_map = {0x0: "sb", 0x1: "sh", 0x2: "sw"}
        name = s_map.get(funct3, "s???")
        return f"{name} {rs2_s}, {imm}({rs1_s})"

    # 4. OP-IMM (Arithmetic with Immediate)
    if opcode == 0x13:
        imm = sign_extend((inst >> 20) & 0xFFF, 12)
        shamt = (inst >> 20) & 0x1F
        if funct3 == 0x0:
            if rs1 == 0:
                return f"li {rd_s}, {imm}"
            return f"addi {rd_s}, {rs1_s}, {imm}"
        if funct3 == 0x1:
            return f"slli {rd_s}, {rs1_s}, {shamt}"
        if funct3 == 0x2:
            return f"slti {rd_s}, {rs1_s}, {imm}"
        if funct3 == 0x3:
            return f"sltiu {rd_s}, {rs1_s}, {imm}"
        if funct3 == 0x4:
            return f"xori {rd_s}, {rs1_s}, {imm}"
        if funct3 == 0x5:
            return f"srai {rd_s}, {rs1_s}, {shamt}" if (
                funct7 & 0x20
            ) else f"srli {rd_s}, {rs1_s}, {shamt}"
        if funct3 == 0x6:
            return f"ori {rd_s}, {rs1_s}, {imm}"
        if funct3 == 0x7:
            return f"andi {rd_s}, {rs1_s}, {imm}"

    # 5. OP (Register-Register & M-Extension)
    if opcode == 0x33:
        if funct7 == 0x01:  # M-Extension
            m_map = {
                0x0: "mul",
                0x1: "mulh",
                0x2: "mulhsu",
                0x3: "mulhu",
                0x4: "div",
                0x5: "divu",
                0x6: "rem",
                0x7: "remu",
            }
            return f"{m_map.get(funct3, 'm???')} {rd_s}, {rs1_s}, {rs2_s}"

        op_map = {
            (0x0, 0x00): "add",
            (0x0, 0x20): "sub",
            (0x1, 0x00): "sll",
            (0x2, 0x00): "slt",
            (0x3, 0x00): "sltu",
            (0x4, 0x00): "xor",
            (0x5, 0x00): "srl",
            (0x5, 0x20): "sra",
            (0x6, 0x00): "or",
            (0x7, 0x00): "and",
        }
        name = op_map.get((funct3, funct7), "op???")
        if name == "add" and rs1 == 0:
            return f"mv {rd_s}, {rs2_s}"
        return f"{name} {rd_s}, {rs1_s}, {rs2_s}"

    # 6. CSR Instructions
    if opcode == 0x73 and funct3 != 0:
        csr_num = (inst >> 20) & 0xFFF
        csr_map = {
            0x000: "ustatus",
            0x005: "utvec",
            0x040: "uscratch",
            0x041: "uepc",
            0x042: "ucause",
            0x008: "vstart",
            0x009: "vxsat",
            0x00A: "vxrm",
            0x00F: "vcsr",
            0x001: "fflags",
            0x002: "frm",
            0x003: "fcsr",
            0xC00: "cycle",
            0xC01: "time",
            0xC02: "instret",
            0xC80: "cycleh",
            0xC82: "instreth",
            0x300: "mstatus",
            0x305: "mtvec",
            0x340: "mscratch",
            0x341: "mepc",
            0x342: "mcause",
        }
        csr_name = csr_map.get(csr_num, f"0x{csr_num:03x}")
        c_map = {
            0x1: "csrrw",
            0x2: "csrrs",
            0x3: "csrrc",
            0x5: "csrrwi",
            0x6: "csrrsi",
            0x7: "csrrci",
        }
        name = c_map.get(funct3, "csr???")
        if funct3 in (0x5, 0x6, 0x7):
            return f"{name} {rd_s}, {csr_name}, {rs1}"
        if rs1 == 0 and name == "csrrs":
            return f"csrr {rd_s}, {csr_name}"
        if rd == 0 and name == "csrrw":
            return f"csrw {csr_name}, {rs1_s}"
        return f"{name} {rd_s}, {csr_name}, {rs1_s}"

    # 7. RVV Vector Instructions (Opcode 0x57, 0x07, 0x27)
    vd_s = vreg_name(rd)
    vs1_s = vreg_name(rs1)
    vs2_s = vreg_name(rs2)
    vm = (inst >> 25) & 0x1
    vm_s = "" if vm == 1 else ", v0.t"

    # Vector Loads / Stores
    if opcode == 0x07:  # Vector Load
        mew = (inst >> 28) & 0x1
        width = (inst >> 12) & 0x7
        w_map = {0: "8", 5: "16", 6: "32"}
        sz = w_map.get(width, "e")
        return f"vle{sz}.v {vd_s}, ({rs1_s}){vm_s}"

    if opcode == 0x27:  # Vector Store
        width = (inst >> 12) & 0x7
        w_map = {0: "8", 5: "16", 6: "32"}
        sz = w_map.get(width, "e")
        return f"vse{sz}.v {vs2_s}, ({rs1_s}){vm_s}"

    # Vector Configuration & Arithmetic (0x57)
    if opcode == 0x57:
        funct6 = (inst >> 26) & 0x3F

        # vsetvli, vsetivli, vsetvl
        if funct3 == 0x7:
            if (inst >> 31) & 0x1 == 0:
                vtypei = (inst >> 20) & 0x7FF
                vsew = (vtypei >> 3) & 0x7
                vlmul = vtypei & 0x7
                sew_s = f"e{8 << vsew}" if vsew <= 3 else "e?"
                lmul_map = {
                    0: "m1",
                    1: "m2",
                    2: "m4",
                    3: "m8",
                    5: "mf8",
                    6: "mf4",
                    7: "mf2"
                }
                lmul_s = lmul_map.get(vlmul, "m?")
                return f"vsetvli {rd_s}, {rs1_s}, {sew_s}, {lmul_s}"
            if ((inst >> 30) & 0x3) == 0x3:
                uimm = (inst >> 15) & 0x1F
                vtypei = (inst >> 20) & 0x3FF
                return f"vsetivli {rd_s}, {uimm}, 0x{vtypei:x}"
            return f"vsetvl {rd_s}, {rs1_s}, {rs2_s}"

        # Vector Integer / Arithmetic operations
        v_ops = {
            0x00: "vadd",
            0x02: "vsub",
            0x03: "vrsub",
            0x04: "vminu",
            0x05: "vmin",
            0x06: "vmaxu",
            0x07: "vmax",
            0x09: "vand",
            0x0A: "vor",
            0x0B: "vxor",
            0x0C: "vrgather",
            0x0E: "vslideup",
            0x0F: "vslidedown",
            0x10: "vadc",
            0x11: "vmadc",
            0x12: "vsbc",
            0x13: "vmsbc",
            0x17: "vmv.v.v",
            0x18: "vmseq",
            0x19: "vmsne",
            0x1A: "vmsltu",
            0x1B: "vmslt",
            0x1C: "vmsleu",
            0x1D: "vmsle",
            0x1E: "vmsgtu",
            0x1F: "vmsgt",
            0x25: "vmul",
            0x27: "vmulh",
            0x26: "vmulhu",
            0x24: "vmulhsu",
            0x20: "vsll",
            0x28: "vsrl",
            0x29: "vsra",
            0x2C: "vdivu",
            0x2D: "vdiv",
            0x2E: "vremu",
            0x2F: "vrem",
            0x39: "vcompress",
        }

        base_name = v_ops.get(funct6, f"v_0x{funct6:02x}")

        if funct3 == 0x0:  # OPIVV
            if base_name == "vrgather":
                return f"vrgather.vv {vd_s}, {vs2_s}, {vs1_s}{vm_s}"
            return f"{base_name}.vv {vd_s}, {vs2_s}, {vs1_s}{vm_s}"
        if funct3 == 0x3:  # OPIVI
            simm5 = sign_extend(rs1, 5)
            if base_name == "vmv.v.v":
                return f"vmv.v.i {vd_s}, {simm5}"
            if base_name == "vslideup":
                return f"vslideup.vi {vd_s}, {vs2_s}, {rs1}{vm_s}"
            if base_name == "vslidedown":
                return f"vslidedown.vi {vd_s}, {vs2_s}, {rs1}{vm_s}"
            return f"{base_name}.vi {vd_s}, {vs2_s}, {simm5}{vm_s}"
        if funct3 == 0x4:  # OPIVX
            if base_name == "vrgather":
                return f"vrgather.vx {vd_s}, {vs2_s}, {rs1_s}{vm_s}"
            if base_name == "vslideup":
                return f"vslideup.vx {vd_s}, {vs2_s}, {rs1_s}{vm_s}"
            if base_name == "vslidedown":
                return f"vslidedown.vx {vd_s}, {vs2_s}, {rs1_s}{vm_s}"
            return f"{base_name}.vx {vd_s}, {vs2_s}, {rs1_s}{vm_s}"
        if funct3 == 0x2:  # OPMVV
            return f"{base_name}.vv {vd_s}, {vs2_s}, {vs1_s}{vm_s}"
        if funct3 == 0x6:  # OPMVX
            return f"{base_name}.vx {vd_s}, {vs2_s}, {rs1_s}{vm_s}"

    return f"0x{inst:08x}"
