.text

# u64 enterUser(u64 rip, u64 user_rsp, usize *resume)
# Runs with interrupts disabled: the kernel must never execute after swapgs
# with IF set (the GS base belongs to the user by then). The iret frame
# restores IF for user mode.
.global enterUser
enterUser:
    cli
    pushq %rbp
    pushq %rbx
    pushq %r12
    pushq %r13
    pushq %r14
    pushq %r15
    movq %rsp, (%rdx)
    movq %rsi, %rax
    pushq $0x1b                # SS: user data | RPL3
    pushq %rax                 # user rsp
    pushq $0x002               # RFLAGS: user mode is preemptible
    pushq $0x23                # CS: user code | RPL3
    pushq %rdi                 # user rip
    xorl %eax, %eax
    xorl %ebx, %ebx
    xorl %ecx, %ecx
    xorl %edx, %edx
    xorl %esi, %esi
    xorl %edi, %edi
    xorl %r8d, %r8d
    xorl %r9d, %r9d
    xorl %r10d, %r10d
    xorl %r11d, %r11d
    swapgs
    iretq

# noreturn leaveUserKernel(usize resume, u64 status)
# Returns to the kernel caller of enterUser with the status in rax.
.global leaveUserKernel
leaveUserKernel:
    swapgs
    movq %rdi, %rsp
    popq %r15
    popq %r14
    popq %r13
    popq %r12
    popq %rbx
    popq %rbp
    movq %rsi, %rax
    ret

.section .note.GNU-stack,"",@progbits
