const kernel = @import("kernel/init.zig");

pub const panic = @import("kernel/panic.zig");

export fn _start() callconv(.naked) void {
    // Limine enters before SSE is enabled. Do the privileged setup and switch
    // to the static kernel stack before any compiler-generated code runs.
    asm volatile (
        \\ cli
        \\ movq %%cr0, %%rax
        \\ andq $-13, %%rax
        \\ orq $2, %%rax
        \\ movq %%rax, %%cr0
        \\ movq %%cr4, %%rax
        \\ orq $0x600, %%rax
        \\ movq %%rax, %%cr4
        \\ leaq __stack_top(%rip), %%rsp
        \\ xorq %%rbp, %%rbp
        \\ call kmain
        \\ cli
        \\ 1: hlt
        \\ jmp 1b
    );
}

export fn kmain() callconv(.c) noreturn {
    kernel.main();
}
