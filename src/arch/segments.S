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
    # FS/GS are left alone on purpose: loading their selectors in 64-bit mode
    # zeroes the segment base, and those bases live in the FS/GS MSRs.
    pushq $0x08
    leaq 1f(%rip), %rax
    pushq %rax
    lretq
1:
    ret

.section .note.GNU-stack,"",@progbits
