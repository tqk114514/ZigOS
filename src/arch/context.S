.text

# void switchTo(*usize save, usize next_rsp)
# Saves the callee-saved registers on the current stack, stores the stack
# pointer through rdi, switches to next_rsp, and returns there.
.global switchTo
switchTo:
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, (%rdi)
    movq %rsi, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    ret

.section .note.GNU-stack,"",@progbits