.text

.macro IRQ num
.global irq_\num
irq_\num:
    pushq $0
    pushq $(32 + \num)
    jmp irq_common
.endm

IRQ 0
IRQ 1
IRQ 2
IRQ 3
IRQ 4
IRQ 5
IRQ 6
IRQ 7
IRQ 8
IRQ 9
IRQ 10
IRQ 11
IRQ 12
IRQ 13
IRQ 14
IRQ 15

irq_common:
    pushq %rax
    pushq %rcx
    pushq %rdx
    pushq %rsi
    pushq %rdi
    pushq %r8
    pushq %r9
    pushq %r10
    pushq %r11
    pushq %rbx
    movq %rsp, %rbx
    andq $-16, %rsp
    call irqHandler
    movq %rbx, %rsp
    popq %rbx
    popq %r11
    popq %r10
    popq %r9
    popq %r8
    popq %rdi
    popq %rsi
    popq %rdx
    popq %rcx
    popq %rax
    addq $16, %rsp
    iretq

.section .rodata
.align 8
.global irq_stub_table
irq_stub_table:
    .quad irq_0, irq_1, irq_2, irq_3, irq_4, irq_5, irq_6, irq_7
    .quad irq_8, irq_9, irq_10, irq_11, irq_12, irq_13, irq_14, irq_15

.section .note.GNU-stack,"",@progbits
