//! External IRQ path and its end-to-end smoke: the RTC periodic interrupt is
//! routed through the IOAPIC to vector 48. The IOAPIC registers live outside
//! the RAM-backed HHDM range and are reached through the paging MMIO window.

const format = @import("../lib/interface.zig").format;
const acpi = @import("acpi.zig");
const apic = @import("apic.zig");
const frame = @import("frame.zig");
const ioapic = @import("ioapic.zig");
const limine = @import("limine.zig");
const paging = @import("paging.zig");
const port = @import("port.zig");
const serial = @import("serial.zig");

pub const vector: u8 = 48;

const rtc_isa_irq: u8 = 8;
const ticks_needed: u64 = 8;

const cmos_index = 0x70;
const cmos_data = 0x71;
const rtc_reg_a = 0x0a;
const rtc_reg_b = 0x0b;
const rtc_reg_c = 0x0c;
const rtc_periodic_enable: u8 = 1 << 6;
const rtc_rate_1024hz: u8 = 0x06; // reg A RS field: 32768 >> (RS - 1)

// Single CPU in M1; the handler runs with interrupts disabled.
var ticks: u64 = 0;

/// Sets up the whole external path (memmap, ACPI, MMIO, IOAPIC, RTC) and
/// enables interrupts. Returns false before touching the interrupt flag when
/// a prerequisite is missing.
pub fn run() bool {
    const console = serial.console;

    const hhdm = limine.hhdmOffset() orelse return false;
    const memmap = limine.memmap() orelse return false;
    frame.init(memmap);
    paging.init(hhdm);

    const rsdp = limine.rsdp() orelse {
        console.write("EXT: no RSDP\n");
        return false;
    };
    if (!acpi.load(rsdp, hhdm)) {
        console.write("EXT: no MADT\n");
        return false;
    }
    const entry = acpi.ioapic() orelse {
        console.write("EXT: no IOAPIC\n");
        return false;
    };

    const mmio = paging.mapMmioPage(entry.base) orelse return false;
    const io = ioapic.attach(mmio, entry.gsi_base);

    console.write("EXT: ioapic base ");
    format.writeHex(console, entry.base, 0);
    console.write(" gsi ");
    format.writeDec(console, entry.gsi_base);
    console.write("\nEXT: version ");
    format.writeHex(console, io.version, 0);
    console.write(" max redir ");
    format.writeDec(console, io.max_redir);
    console.write("\n");

    if (!apic.hasX2Apic()) return false;
    apic.enable();

    const gsi = acpi.gsiFor(rtc_isa_irq);
    io.maskAll();
    if (!io.program(gsi, vector, acpi.isoFlags(rtc_isa_irq), @truncate(apic.id()))) {
        console.write("EXT: gsi out of range\n");
        return false;
    }

    console.write("EXT: gsi ");
    format.writeDec(console, gsi);
    console.write(" -> vector ");
    format.writeDec(console, vector);
    console.write("\n");

    rtcStartPeriodic();

    // SAFETY: GDT/IDT and the full IOAPIC route are ready; enable interrupts.
    asm volatile ("sti");
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn handleIrq() void {
    // Reading register C clears the RTC's pending flags before the EOI.
    _ = readRtc(rtc_reg_c);
    apic.eoi();

    ticks += 1;
    if (ticks < ticks_needed) return;

    serial.console.write("IRQ OK\n");
    port.outb(0xf4, 0x18); // 49
    while (true) {
        // SAFETY: exit path; interrupts stay disabled.
        asm volatile ("cli\n\thlt");
    }
}

fn rtcStartPeriodic() void {
    const reg_a = readRtc(rtc_reg_a);
    const reg_b = readRtc(rtc_reg_b);
    writeRtc(rtc_reg_a, (reg_a & 0xf0) | rtc_rate_1024hz);
    writeRtc(rtc_reg_b, reg_b | rtc_periodic_enable);
}

fn readRtc(reg: u8) u8 {
    // Bit 7 of the index port masks the NMI line during the access.
    port.outb(cmos_index, reg | 0x80);
    return port.inb(cmos_data);
}

fn writeRtc(reg: u8, value: u8) void {
    port.outb(cmos_index, reg | 0x80);
    port.outb(cmos_data, value);
}
