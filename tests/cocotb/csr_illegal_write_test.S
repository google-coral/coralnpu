.section .text
.balign 4
.global _start
.type _start, @function
_start:
.global main
.type main, @function
main:
    li t0, 2
    csrw vl, t0
    csrw vlenb, t0
    csrr t0, vl
    csrr t0, vlenb
    # mpause (0x08000073) halts/finishes test in simulation
    .word 0x08000073
1:
    j 1b
