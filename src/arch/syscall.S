.text

# SYSCALL entry. The user GS base is empty; KERNEL_GS_BASE holds the per-CPU
# block. Frame layout matches syscall.Frame (r15 first, user_rsp last).
.global syscallEntry
syscallEntry:
    swapgs
    movq %rsp, %gs:32          # user rsp scratch
    movq %gs:24, %rsp          # per-CPU kernel entry stack
    pushq %gs:32
    pushq %r11                 # user rflags
    pushq %rcx                 # user rip
    pushq %rax                 # syscall number
    pushq %rdi
    pushq %rsi
    pushq %rdx
    pushq %rbx
    pushq %r15
    movq %rsp, %rdi            # frame pointer
    subq $8, %rsp              # keep the call 16-byte aligned
    call syscallHandler
    addq $8, %rsp
    popq %r15
    popq %rbx
    popq %rdx
    popq %rsi
    popq %rdi
    addq $8, %rsp              # number slot (result in rax)
    popq %rcx
    popq %r11
    movq (%rsp), %rsp
    swapgs
    sysretq

.section .note.GNU-stack,"",@progbits
