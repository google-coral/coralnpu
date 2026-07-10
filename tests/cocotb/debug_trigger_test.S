.balign 4
.global main
.type main, @function
main:
    li x1, 0
    addi x1, x1, 1
.global trigger_target
trigger_target:
    addi x1, x1, 1
    addi x1, x1, 1
.global end_target
end_target:
    nop
