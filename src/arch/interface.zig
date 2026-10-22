const hal = @import("../hal/interface.zig");
const port = @import("port.zig");
const serial = @import("serial.zig");
const limine = @import("limine.zig");
const backtrace = @import("backtrace.zig");

pub const serial_console = hal.Console{ .write_fn = serial.write };

pub fn disableInterrupts() void {
    // SAFETY: privileged instruction executed by the kernel.
    asm volatile ("cli");
}

pub fn initSerial() void {
    serial.init();
}

pub fn halt() noreturn {
    while (true) {
        // SAFETY: kernel halt loop with interrupts disabled; NMI may resume it.
        asm volatile ("cli\n\thlt");
    }
}

pub fn qemuExit(code: u8) void {
    // QEMU isa-debug-exit exits with (code << 1) | 1. On real hardware this
    // port is unused; callers halt after this returns.
    port.outb(0xf4, code);
}

pub fn limineBaseRevisionSupported() bool {
    return limine.baseRevisionSupported();
}

pub fn limineLoadedBaseRevision() u64 {
    return limine.loadedBaseRevision();
}

pub fn printBacktrace(console: hal.Console) void {
    backtrace.print(console);
}
