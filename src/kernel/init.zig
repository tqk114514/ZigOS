const arch = @import("../arch/interface.zig");
const format = @import("../lib/interface.zig").format;
const config = @import("config");

pub fn main() noreturn {
    arch.initSerial();
    const console = arch.serial_console;

    console.write("ZigOS M1\n");
    console.write("limine base revision: ");
    format.writeHex(console, arch.limineLoadedBaseRevision(), 0);
    console.write("\n");

    if (!arch.limineBaseRevisionSupported()) {
        console.write("Limine base revision unsupported\n");
        arch.halt();
    }

    arch.initGdt();
    arch.initIdt();

    if (config.nmi_smoke) {
        asm volatile ("int $2");
    }

    if (config.exception_smoke) {
        asm volatile ("int3");
    }

    if (config.panic_smoke) {
        var probe: [1]u8 = .{0};
        const index: usize = @intCast(arch.limineLoadedBaseRevision());
        probeWrite(&probe, index);
    }

    console.write("ZigOS M1 OK\n");
    arch.qemuExit(0x10);
    arch.halt();
}

noinline fn probeWrite(array: *[1]u8, index: usize) void {
    array[index] = 1;
}
