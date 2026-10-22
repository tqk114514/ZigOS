//! x2APIC timer and the first returnable IRQ handler.

const port = @import("port.zig");
const serial = @import("serial.zig");

const apic_base_msr = 0x1b;
const x2apic_svr = 0x80f;
const x2apic_eoi = 0x80b;
const x2apic_lvt_timer = 0x832;
const x2apic_timer_initial = 0x838;
const x2apic_timer_divide = 0x83e;

const timer_vector: u32 = 32;
const spurious_vector: u32 = 0x2f;
const timer_ticks_needed: u64 = 3;

// Single CPU in M1; the timer handler runs with interrupts disabled.
var ticks: u64 = 0;

pub fn init() void {
    const console = serial.console;
    if (!hasX2Apic()) {
        console.write("x2APIC unavailable\n");
        port.outb(0xf4, 0x15); // 43
        halt();
    }

    // Enable x2APIC mode (bit 10) and the APIC global enable (bit 11).
    wrmsr(apic_base_msr, rdmsr(apic_base_msr) | (1 << 10) | (1 << 11));
    // Software-enable the APIC; spurious vector is inside the IRQ stub table.
    wrmsr(x2apic_svr, 0x100 | spurious_vector);
    // Periodic timer on vector 32.
    wrmsr(x2apic_lvt_timer, timer_vector | (1 << 17));
    wrmsr(x2apic_timer_divide, 0x3); // divide by 16
    wrmsr(x2apic_timer_initial, 0x100000);

    // SAFETY: IDT/GDT are ready and the timer is programmed; enable interrupts.
    asm volatile ("sti");
}

pub fn handleIrq() void {
    // SAFETY: EOI MSR write at CPL0; the timer IRQ is the only source.
    wrmsr(x2apic_eoi, 0);
    ticks += 1;
    if (ticks < timer_ticks_needed) return;

    serial.console.write("TIMER OK\n");
    port.outb(0xf4, 0x14); // 41
    halt();
}

fn halt() noreturn {
    while (true) {
        // SAFETY: fatal/exit path; interrupts stay disabled.
        asm volatile ("cli\n\thlt");
    }
}

fn hasX2Apic() bool {
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

fn rdmsr(msr: u32) u64 {
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

fn wrmsr(msr: u32, value: u64) void {
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
