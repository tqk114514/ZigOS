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

pub fn enableSse() void {
    // Limine enters with OSFXSR/OSXMMEXCPT clear; the compiler may emit SSE
    // for ordinary 16-byte moves. Enable it before any such instruction runs.
    var cr0: u64 = undefined;
    // SAFETY: privileged control-register access at CPL0.
    asm volatile ("mov %%cr0, %[out]"
        : [out] "=r" (cr0),
    );
    cr0 &= ~@as(u64, (1 << 2) | (1 << 3)); // clear EM, TS
    cr0 |= @as(u64, 1 << 1); // set MP
    // SAFETY: privileged control-register access at CPL0.
    asm volatile ("mov %[in], %%cr0"
        :
        : [in] "r" (cr0),
        : .{ .memory = true });

    var cr4: u64 = undefined;
    // SAFETY: privileged control-register access at CPL0.
    asm volatile ("mov %%cr4, %[out]"
        : [out] "=r" (cr4),
    );
    cr4 |= @as(u64, (1 << 9) | (1 << 10)); // OSFXSR, OSXMMEXCPT
    // SAFETY: privileged control-register access at CPL0.
    asm volatile ("mov %[in], %%cr4"
        :
        : [in] "r" (cr4),
        : .{ .memory = true });
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
