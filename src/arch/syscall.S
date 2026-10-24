.text

# SYSCALL entry. The user GS base is empty; KERNEL_GS_BASE holds the per-CPU
# block. Frame layout matches syscall.Frame (r15 first, user_rsp last).
.global syscallEntry
syscallEntry:
    swapgs
    movq %rsp, %gs:32          # user rsp scratch
    movq %gs:24, %rsp          # per-CPU kernel entry stack
    # Caller-saved registers the handler may clobber but the user ABI (and
    # Linux) preserves across a syscall. user_rsp sits above them so the
    # epilogue can pop them and then switch to the user stack.
    pushq %gs:32
    pushq %r10
    pushq %r9
    pushq %r8
    pushq %r11                 # user rflags
    pushq %rcx                 # user rip
    pushq %rax                 # syscall number
    pushq %rdi
    pushq %rsi
    pushq %rdx
    pushq %rbx
    pushq %r15
    movq %rsp, %rdi            # frame pointer
    call syscallHandler
    popq %r15
    popq %rbx
    popq %rdx
    popq %rsi
    popq %rdi
    addq $8, %rsp              # number slot (result in rax)
    popq %rcx
    popq %r11
    popq %r8
    popq %r9
    popq %r10
    movq (%rsp), %rsp
    swapgs
    sysretq

.section .note.GNU-stack,"",@progbits
