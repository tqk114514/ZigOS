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

# External IRQ stub (see extirq.zig); the vector is outside the PIC range.
.global irq_ext
irq_ext:
    pushq $0
    pushq $48
    jmp irq_common

# Reschedule IPI stub (see sched); the kernel registers the handler.
.global irq_ipi
irq_ipi:
    pushq $0
    pushq $50
    jmp irq_common

# TLB shootdown IPI stub (see tlb.zig); registered at boot.
.global irq_tlb
irq_tlb:
    pushq $0
    pushq $51
    jmp irq_common

irq_common:
    # Interrupts from ring3 carry an empty GS base; swap to the per-CPU block.
    testb $3, 24(%rsp)
    jz 1f
    swapgs
1:
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
    # The vector slot sits above the 10 saved registers.
    movq 80(%rbx), %rdi
    call irqHandler
    call irqPreemptCheck
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
    testb $3, 8(%rsp)
    jz 1f
    swapgs
1:
    iretq

.section .rodata
.align 8
.global irq_stub_table
irq_stub_table:
    .quad irq_0, irq_1, irq_2, irq_3, irq_4, irq_5, irq_6, irq_7
    .quad irq_8, irq_9, irq_10, irq_11, irq_12, irq_13, irq_14, irq_15

.section .note.GNU-stack,"",@progbits