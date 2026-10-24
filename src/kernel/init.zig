const arch = @import("../arch/interface.zig");
const format = @import("../lib/interface.zig").format;
const drivers = @import("../drivers/interface.zig");
const fs = @import("../fs/interface.zig");
const object = @import("../object/interface.zig");
const syscall_dispatch = @import("syscall.zig");
const sched = @import("../sched/interface.zig");
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

    if (!arch.initPerCpu()) {
        console.write("PERCPU FAIL\n");
        arch.qemuExit(0x1d); // 59
        arch.halt();
    }
    arch.initGdt();
    arch.initIdt();
    arch.initSyscall();
    syscall_dispatch.init();
    arch.initTlb();

    const boot_image = arch.moduleImage("/initramfs.img");
    fs.init(boot_image);
    if (boot_image) |blob| {
        console.write("INITRAMFS: ");
        format.writeDec(console, blob.len);
        console.write(" bytes ");
        console.write(if (fs.ready()) " ok" else " invalid");
        console.write("\n");
    } else {
        console.write("INITRAMFS: none\n");
    }

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

    if (config.smp_smoke) {
        if (arch.runSmpSmoke()) {
            console.write("SMP OK\n");
            arch.qemuExit(0x1c); // 57
        } else {
            console.write("SMP FAIL\n");
            arch.qemuExit(0x1d); // 59
        }
        arch.halt();
    }

    if (config.sched_smoke) {
        if (!arch.initMemorySubsystems()) {
            console.write("SCHED FAIL\n");
            arch.qemuExit(0x1f); // 63
            arch.halt();
        }
        arch.setVectorHandler(arch.timer_vector, sched.onTimer);
        arch.setVectorHandler(arch.ipi_vector, sched.onIpi);
        arch.setPreemptHook(sched.preempt);
        arch.setApHandler(sched.apEntry);
        if (arch.startAps() and sched.runSmoke() and arch.tlbProbe()) {
            console.write("SCHED OK\n");
            arch.qemuExit(0x1e); // 61
        } else {
            console.write("SCHED FAIL\n");
            arch.qemuExit(0x1f); // 63
        }
        arch.halt();
    }

    if (config.user_smoke) {
        arch.setVectorHandler(arch.timer_vector, sched.onTimer);
        arch.setVectorHandler(arch.ipi_vector, sched.onIpi);
        arch.setPreemptHook(sched.preempt);
        arch.setApHandler(sched.apEntry);
        if (!arch.initMemorySubsystems()) {
            console.write("USER FAIL\n");
            arch.qemuExit(0x23); // 71
            arch.halt();
        }
        _ = arch.startAps();
        const started = sched.startKernelScheduler() and sched.waitApReady();
        const ticks_before = sched.ticksNow();
        const switches_before = sched.switchesNow();
        const ok = started and arch.runUserSmoke();
        const preemptions = sched.ticksNow() - ticks_before;
        const switches = sched.switchesNow() - switches_before;

        var a2_ok = true;
        if (ok and arch.cpuCount() >= 2) {
            if (!arch.prepareUserSmp()) {
                a2_ok = false;
            } else if (!sched.spawn(&userSmpThread, 1)) {
                a2_ok = false;
            } else {
                a2_ok = arch.finishUserSmp();
            }
        }

        if (ok and a2_ok and preemptions >= 2 and switches >= 2) {
            console.write("USER: preempt ticks ");
            format.writeDec(console, preemptions);
            console.write(" switches ");
            format.writeDec(console, switches);
            console.write(" preempted\n");
            console.write("USER OK\n");
            arch.qemuExit(0x22); // 69
        } else {
            console.write("USER FAIL\n");
            arch.qemuExit(0x23); // 71
        }
        arch.halt();
    }

    if (config.blk_smoke) {
        if (arch.initMemorySubsystems() and arch.initAcpi() and
            drivers.probe() and drivers.runSmoke())
        {
            console.write("BLK OK\n");
            arch.qemuExit(0x24); // 73
        } else {
            console.write("BLK FAIL\n");
            arch.qemuExit(0x25); // 75
        }
        arch.halt();
    }

    if (config.shell_smoke) {
        const image = arch.moduleImage("/shell.elf");
        var status: ?u64 = null;
        var reclaimed = false;
        if (arch.initMemorySubsystems()) {
            const frames_before = arch.frameFreeCount();
            if (image) |bytes| status = arch.runUserShell(bytes, syscall_dispatch.currentHandle());
            reclaimed = arch.frameFreeCount() == frames_before;
        }
        if (reclaimed) console.write("SHELL: space reclaimed\n");
        if (status != null and status.? == 0 and reclaimed) {
            console.write("SHELL OK\n");
            arch.qemuExit(0x26); // 77
        } else {
            console.write("SHELL FAIL\n");
            arch.qemuExit(0x27); // 79
        }
        arch.halt();
    }

    if (config.object_smoke) {
        if (object.runSmoke()) {
            console.write("OBJECT OK\n");
            arch.qemuExit(0x20); // 65
        } else {
            console.write("OBJECT FAIL\n");
            arch.qemuExit(0x21); // 67
        }
        arch.halt();
    }

    if (config.bench_smoke) {
        if (!arch.runBench()) {
            console.write("BENCH FAIL\n");
            arch.qemuExit(0x1b); // 55
        } else {
            arch.qemuExit(0x1a); // 53
        }
        arch.halt();
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

fn userSmpThread() callconv(.c) void {
    _ = arch.runUserSmpThread();
}

noinline fn probeWrite(array: *[1]u8, index: usize) void {
    array[index] = 1;
}
