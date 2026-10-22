//! x2APIC periodic timer and the first returnable IRQ handler.

const apic = @import("apic.zig");
const port = @import("port.zig");
const serial = @import("serial.zig");

const x2apic_lvt_timer = 0x832;
const x2apic_timer_initial = 0x838;
const x2apic_timer_divide = 0x83e;

const timer_vector: u32 = 32;
const timer_ticks_needed: u64 = 3;

// Single CPU in M1; the timer handler runs with interrupts disabled.
var ticks: u64 = 0;

pub fn init() void {
    const console = serial.console;
    if (!apic.hasX2Apic()) {
        console.write("x2APIC unavailable\n");
        port.outb(0xf4, 0x15); // 43
        halt();
    }

    apic.enable();
    programPeriodic();

    // SAFETY: IDT/GDT are ready and the timer is programmed; enable interrupts.
    asm volatile ("sti");
}

/// Programs the periodic timer for the current CPU. The caller sets IF.
pub fn programPeriodic() void {
    apic.wrmsr(x2apic_lvt_timer, timer_vector | (1 << 17));
    apic.wrmsr(x2apic_timer_divide, 0x3); // divide by 16
    apic.wrmsr(x2apic_timer_initial, 0x100000);
}

pub fn handleIrq() void {
    apic.eoi();
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
