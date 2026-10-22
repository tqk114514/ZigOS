.text

.global loadGdtAndTss
loadGdtAndTss:
    lgdt (%rdi)
    movw %si, %ax
    ltr %ax
    movw $0x10, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw %ax, %fs
    movw %ax, %gs
    pushq $0x08
    leaq 1f(%rip), %rax
    pushq %rax
    lretq
1:
    ret

.section .note.GNU-stack,"",@progbits
