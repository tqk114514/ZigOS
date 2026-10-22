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

    if (config.timer_smoke) {
        arch.initTimer();
        while (true) {
            asm volatile ("hlt");
        }
    }

    if (config.mem_smoke) {
        if (arch.runMemorySmoke()) {
            console.write("MEM OK\n");
            arch.qemuExit(0x16); // 45
        } else {
            console.write("MEM FAIL\n");
            arch.qemuExit(0x17); // 47
        }
        arch.halt();
    }

    if (config.irq_smoke) {
        if (!arch.runExternalSmoke()) {
            console.write("IRQ FAIL\n");
            arch.qemuExit(0x19); // 51
            arch.halt();
        }
        while (true) {
            asm volatile ("hlt");
        }
    }

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
