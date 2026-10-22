//! SMP bring-up via the Limine MP protocol. The bootloader starts and parks
//! the APs on its own stacks; the BSP releases them once the boot tables and
//! the per-CPU array exist. APs load the shared GDT/TSS/IDT, set up their
//! per-CPU block, and park.

const format = @import("../lib/interface.zig").format;
const cpu = @import("cpu.zig");
const exceptions = @import("exceptions.zig");
const gdt = @import("gdt.zig");
const limine = @import("limine.zig");
const percpu = @import("percpu.zig");
const serial = @import("serial.zig");

const ap_timeout_ticks: u64 = 4_000_000_000;

/// Sets up the per-CPU block for the boot processor and resets the AP flags.
pub fn initBsp() bool {
    percpu.init();
    const mp = limine.mp() orelse {
        // Bootloader without MP support: keep running as a single CPU.
        const me = percpu.setup(0, 0);
        percpu.markOnline(me);
        return true;
    };
    const cpus = mp.cpus orelse return false;

    const count: usize = @intCast(@min(mp.cpu_count, @as(u64, percpu.max_cpus)));
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (cpus[index].lapic_id == mp.bsp_lapic_id) {
            const me = percpu.setup(index, mp.bsp_lapic_id);
            percpu.markOnline(me);
            return true;
        }
    }
    return false;
}

/// Releases every AP and waits for them to report online. Smoke path.
pub fn run() bool {
    const console = serial.console;
    const mp = limine.mp() orelse return false;
    const cpus = mp.cpus orelse return false;

    // M2 tracks a bounded CPU count; the smoke machine must fit.
    if (mp.cpu_count > percpu.max_cpus) return false;
    const count: usize = @intCast(mp.cpu_count);

    const entry: *const fn (*limine.MpInfo) callconv(.c) void = @ptrCast(&apEntry);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (cpus[index].lapic_id == mp.bsp_lapic_id) continue;
        @atomicStore(@TypeOf(cpus[index].goto_address), &cpus[index].goto_address, entry, .release);
    }

    const deadline = cpu.rdtsc() + ap_timeout_ticks;
    while (onlineCount(count) != count) {
        if (cpu.rdtsc() > deadline) {
            console.write("SMP: timeout with ");
            format.writeDec(console, onlineCount(count));
            console.write(" of ");
            format.writeDec(console, count);
            console.write(" online\n");
            return false;
        }
        cpu.pause();
    }

    // Each block proves its own CPU filled it: self/index/apic_id only become
    // visible through the release store that also published `online`.
    index = 0;
    while (index < count) : (index += 1) {
        const block = percpu.at(index);
        if (!percpu.isOnline(block)) return false;
        if (block.self != block) return false;
        if (block.index != @as(u32, @intCast(index))) return false;
        if (block.apic_id != cpus[index].lapic_id) return false;

        console.write("SMP: cpu ");
        format.writeDec(console, index);
        console.write(" apic ");
        format.writeDec(console, block.apic_id);
        console.write("\n");
    }
    console.write("SMP: cpus ");
    format.writeDec(console, count);
    console.write(" online ");
    format.writeDec(console, count);
    console.write("\n");
    return true;
}

fn onlineCount(count: usize) usize {
    var online: usize = 0;
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (percpu.isOnline(percpu.at(index))) online += 1;
    }
    return online;
}

export fn apEntry() callconv(.naked) void {
    // An AP enters like the BSP: SSE disabled, x2APIC per Limine. RDI holds
    // its mp_info pointer and must survive until apMain.
    asm volatile (
        \\ cli
        \\ movq %%cr0, %%rax
        \\ andq $-13, %%rax
        \\ orq $2, %%rax
        \\ movq %%rax, %%cr0
        \\ movq %%cr4, %%rax
        \\ orq $0x600, %%rax
        \\ movq %%rax, %%cr4
        \\ call apMain
        \\ cli
        \\ 1: hlt
        \\ jmp 1b
    );
}

export fn apMain(info: *limine.MpInfo) callconv(.c) noreturn {
    const mp = limine.mp() orelse park();
    const cpus = mp.cpus orelse park();
    const count: usize = @intCast(@min(mp.cpu_count, @as(u64, percpu.max_cpus)));
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (cpus[index] == info) break;
    }
    if (index == count) park();

    const block = percpu.setup(index, info.lapic_id);
    gdt.load();
    exceptions.load();
    if (percpu.current() != block) park();
    percpu.markOnline(block);
    park();
}

fn park() noreturn {
    while (true) {
        // SAFETY: parked AP with interrupts disabled; NMI/reset may wake it.
        asm volatile ("cli\n\thlt");
    }
}
