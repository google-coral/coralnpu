.section .data
.balign 16
.global trap_info
trap_info:
    .word 0   // [0] trap_count
    .word 0   // [1] last_mcause
    .word 0   // [2] last_mtval
    .word 0   // [3] vl_val
    .word 0   // [4] vlenb_val
    .word 0   // [5] vtype_val

.section .text
.balign 4
.option norelax
.global _start
.type _start, @function
_start:
.global main
.type main, @function
main:
    la t0, trap_handler
    csrw mtvec, t0

    li t0, 2
    # 1. Attempt CSRRW to read-only vl (0xc20)
    csrw vl, t0
    # 2. Attempt CSRRW to read-only vlenb (0xc22)
    csrw vlenb, t0
    # 3. Attempt CSRRW to read-only vtype (0xc21)
    csrw vtype, t0
    # 4. Attempt CSRRS with rs1 != x0 to read-only vl (0xc20)
    csrs vl, t0
    # 5. Attempt CSRRC with rs1 != x0 to read-only vlenb (0xc22)
    csrc vlenb, t0
    # 6. Attempt CSRRS with rs1 != x0 to read-only vtype (0xc21)
    csrs vtype, t0
    # 7. Attempt CSRRC with rs1 != x0 to read-only vtype (0xc21)
    csrc vtype, t0
    # 8. Attempt CSRRWI with uimm = 0 to read-only vl (0xc20)
    csrwi vl, 0
    # 9. Attempt CSRRWI with uimm = 0 to read-only vtype (0xc21)
    csrwi vtype, 0

    # 10. Read vl, vlenb, and vtype (CSRRS with rs1 = x0, must NOT trap)
    csrr t1, vl
    csrr t2, vlenb
    csrr t6, vtype
    la t3, trap_info
    sw t1, 12(t3)
    sw t2, 16(t3)
    sw t6, 20(t3)

    # Verify all 9 illegal CSR writes trapped
    lw t4, 0(t3)
    li t5, 9
    bne t4, t5, fail

    # mpause (0x08000073) halts/finishes test in simulation
    .word 0x08000073
1:
    j 1b

fail:
    ebreak
    j fail

.balign 4
trap_handler:
    la t6, trap_info
    csrr a1, mcause
    csrr a2, mepc
    csrr a3, mtval
    # Verify mcause == 2 (Illegal instruction)
    li a4, 2
    bne a1, a4, fail
    # Increment trap_count and store last_mcause, last_mtval
    lw a5, 0(t6)
    addi a5, a5, 1
    sw a5, 0(t6)
    sw a1, 4(t6)
    sw a3, 8(t6)
    # Advance mepc past faulting 4-byte instruction
    addi a2, a2, 4
    csrw mepc, a2
    mret

