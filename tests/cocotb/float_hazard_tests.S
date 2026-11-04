.balign 4
.global main
.type main, @function
main:
    # Prepare stack
    addi sp, sp, -32
    li t0, 0x3f800000 # 1.0f
    sw t0, 0(sp)
    li t0, 0x40000000 # 2.0f
    sw t0, 4(sp)
    li t0, 0x40400000 # 3.0f
    sw t0, 8(sp)
    li t0, 0x40800000 # 4.0f
    sw t0, 12(sp)

    # Load constants
    flw f1, 0(sp) # 1.0f
    flw f2, 4(sp) # 2.0f
    flw f3, 8(sp) # 3.0f

    # =========================================================================
    # Test 1: same-cycle RAW on rs2 for fmadd.s (fd = fs1 * fs2 + fs3)
    # =========================================================================
    fmv.s f4, f1 # Initialize f4 with stale value (1.0f)
    flw f4, 12(sp) # load 4.0f
    lbu t2, 0(sp) # Dummy
    sb t2, 0(sp)  # Dummy
    fmadd.s f5, f2, f4, f3, rne

    fmv.x.w t0, f5
    li t1, 0x41300000 # 11.0f
    bne t0, t1, fail

    # =========================================================================
    # Test 2: same-cycle RAW on rs2 for fnmadd.s (fd = -(fs1 * fs2 + fs3))
    # =========================================================================
    fmv.s f4, f1
    flw f4, 12(sp)
    lbu t2, 0(sp)
    sb t2, 0(sp)
    fnmadd.s f5, f2, f4, f3, rne

    fmv.x.w t0, f5
    li t1, 0xc1300000 # -11.0f
    bne t0, t1, fail

    # =========================================================================
    # Test 3: same-cycle RAW on rs2 for fnmsub.s (fd = -(fs1 * fs2 - fs3))
    # =========================================================================
    fmv.s f4, f1
    flw f4, 12(sp)
    lbu t2, 0(sp)
    sb t2, 0(sp)
    fnmsub.s f5, f2, f4, f3, rne

    fmv.x.w t0, f5
    li t1, 0xc0a00000 # -5.0f
    bne t0, t1, fail

    # =========================================================================
    # Test 4: same-cycle RAW on rs2 for fmsub.s (fd = fs1 * fs2 - fs3)
    # =========================================================================
    fmv.s f4, f1
    flw f4, 12(sp)
    lbu t2, 0(sp)
    sb t2, 0(sp)
    fmsub.s f5, f2, f4, f3, rne

    fmv.x.w t0, f5
    li t1, 0x40a00000 # 5.0f
    bne t0, t1, fail

    # =========================================================================
    # Test 5: different-cycle RAW on rs2 for fmsub.s (fd = fs1 * fs2 - fs3)
    # =========================================================================
    fmv.s f4, f1
    flw f4, 12(sp)
    nop
    nop
    nop
    nop
    fmsub.s f5, f2, f4, f3, rne

    fmv.x.w t0, f5
    li t1, 0x40a00000 # 5.0f
    bne t0, t1, fail

    # =========================================================================
    # Test 6: same-cycle RAW on rs2 for fadd.s (fd = fs1 + fs2)
    # =========================================================================
    fmv.s f4, f1
    flw f4, 12(sp)
    lbu t2, 0(sp)
    sb t2, 0(sp)
    fadd.s f5, f2, f4, rne

    fmv.x.w t0, f5
    li t1, 0x40c00000 # 6.0f
    bne t0, t1, fail

    # =========================================================================
    # Test 7: RAW on rs1 for fnmsub.s when rs3 = f30 (5'b11110)
    # Regression test: R4 rs3 in inst[31:27] must not alias OP-FP funct5
    # for fmv.w.x (5'b11110), which previously set scalar_rs1=1, float_rs1=0.
    # =========================================================================
    fmv.s f30, f3 # f30 = 3.0f
    fmv.s f4, f1  # f4 = stale 1.0f
    flw f4, 12(sp) # load f4 = 4.0f
    sb t2, 0(sp)
    fnmsub.s f5, f4, f2, f30, rne # -(4.0f * 2.0f - 3.0f) = -5.0f

    fmv.x.w t0, f5
    li t1, 0xc0a00000 # -5.0f
    bne t0, t1, fail

    # =========================================================================
    # Test 8: RAW on rs1 for fmadd.s when rs3 = f26 (5'b11010)
    # Regression test: R4 rs3 in inst[31:27] must not alias OP-FP funct5
    # for fcvt.s.w (5'b11010), which previously set scalar_rs1=1, float_rs1=0.
    # =========================================================================
    fmv.s f26, f3 # f26 = 3.0f
    fmv.s f4, f1  # f4 = stale 1.0f
    flw f4, 12(sp) # load f4 = 4.0f
    sb t2, 0(sp)
    fmadd.s f5, f4, f2, f26, rne # 4.0f * 2.0f + 3.0f = 11.0f

    fmv.x.w t0, f5
    li t1, 0x41300000 # 11.0f
    bne t0, t1, fail

    # Restore stack
    addi sp, sp, 32
    j pass

fail:
    ebreak

pass:
    .word 0x08000073
