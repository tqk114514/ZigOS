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
