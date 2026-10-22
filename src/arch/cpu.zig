//! CPU primitives shared by the arch modules.

pub fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    // SAFETY: rdtsc is unprivileged; lfence keeps it from being speculated
    // ahead of prior work.
    asm volatile ("lfence\n\trdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        :
        : .{ .memory = true });
    return (@as(u64, high) << 32) | low;
}

pub fn pause() void {
    // SAFETY: pause is unprivileged and side-effect free.
    asm volatile ("pause");
}

pub fn interruptsEnabled() bool {
    var flags: u64 = undefined;
    // SAFETY: pushfq is unprivileged and only reads the flags register.
    asm volatile ("pushfq\n\tpopq %[out]"
        : [out] "=r" (flags),
    );
    return (flags & (1 << 9)) != 0;
}

pub fn disableInterrupts() void {
    // SAFETY: privileged instruction executed by the kernel.
    asm volatile ("cli" ::: .{ .memory = true });
}

pub fn enableInterrupts() void {
    // SAFETY: privileged instruction executed by the kernel.
    asm volatile ("sti" ::: .{ .memory = true });
}

/// Disables interrupts and reports whether they had been enabled.
pub fn saveAndDisableInterrupts() bool {
    const enabled = interruptsEnabled();
    disableInterrupts();
    return enabled;
}

pub fn restoreInterrupts(enabled: bool) void {
    if (enabled) enableInterrupts();
}
