.text

.global pf_stub
pf_stub:
    pushq $14
    jmp pf_common

pf_common:
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
    # The CPU frame (vector/error/RIP/...) sits above the 10 saved registers.
    leaq 80(%rbx), %rdi
    call pageFaultHandler
    testb %al, %al
    jz 1f
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
1:
    leaq 80(%rbx), %rdi
    call exceptionHandler

.section .note.GNU-stack,"",@progbits