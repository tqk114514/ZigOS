//! x2APIC low-level access shared by the timer and the external IRQ path:
//! MSR primitives, APIC enable, EOI, and the local APIC ID.

const apic_base_msr = 0x1b;
const x2apic_id = 0x802;
const x2apic_eoi = 0x80b;
const x2apic_svr = 0x80f;
const spurious_vector: u32 = 0x2f;

/// True when CPUID reports x2APIC support (leaf 1, ECX bit 21).
pub fn hasX2Apic() bool {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    // SAFETY: CPUID leaf 1 is architectural and side-effect free.
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (@as(u32, 1)),
          [subleaf] "{ecx}" (@as(u32, 0)),
        : .{ .memory = true });
    return (ecx & (1 << 21)) != 0;
}

/// Enables x2APIC mode and software-enables the APIC; call once, early.
pub fn enable() void {
    // Enable x2APIC mode (bit 10) and the APIC global enable (bit 11).
    wrmsr(apic_base_msr, rdmsr(apic_base_msr) | (1 << 10) | (1 << 11));
    // Software-enable the APIC; spurious vector is inside the IRQ stub table.
    wrmsr(x2apic_svr, 0x100 | spurious_vector);
}

/// Signals end-of-interrupt for the vector currently in service.
pub fn eoi() void {
    wrmsr(x2apic_eoi, 0);
}

/// The local APIC ID of the current CPU.
pub fn id() u32 {
    return @truncate(rdmsr(x2apic_id));
}

/// Reads a model-specific register (privileged).
pub fn rdmsr(msr: u32) u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    // SAFETY: privileged MSR read at CPL0.
    asm volatile ("rdmsr"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        : [msr] "{ecx}" (msr),
        : .{ .memory = true });
    return (@as(u64, high) << 32) | low;
}

/// Writes a model-specific register (privileged).
pub fn wrmsr(msr: u32, value: u64) void {
    const low: u32 = @truncate(value);
    const high: u32 = @truncate(value >> 32);
    // SAFETY: privileged MSR write at CPL0.
    asm volatile ("wrmsr"
        :
        : [msr] "{ecx}" (msr),
          [low] "{eax}" (low),
          [high] "{edx}" (high),
        : .{ .memory = true });
}
