//! SMP bring-up via the Limine MP protocol. The bootloader starts and parks
//! the APs on its own stacks; the BSP releases them once the boot tables and
//! the per-CPU array exist. APs load the shared GDT/TSS/IDT, set up their
//! per-CPU block, and park.

const format = @import("../lib/interface.zig").format;
const cpu = @import("cpu.zig");
const exceptions = @import("exceptions.zig");
const frame = @import("frame.zig");
const gdt = @import("gdt.zig");
const limine = @import("limine.zig");
const percpu = @import("percpu.zig");
const serial = @import("serial.zig");

const ap_timeout_ticks: u64 = 4_000_000_000;

// Concurrent allocator stress handed to the APs through mp_info.extra_argument
// before they are released; the BSP runs the same workload.
const stress_magic: u64 = 0x5354_5245_5353;
const stress_iterations: u64 = 2000;
const stress_batch: usize = 4;

var stress_done: u32 = 0; // atomic
var stress_errors: u32 = 0; // atomic

// Registered by the composition root before APs are released.
var ap_handler: ?*const fn () callconv(.c) noreturn = null;

pub fn setApHandler(handler: ?*const fn () callconv(.c) noreturn) void {
    ap_handler = handler;
}

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
    percpu.setCount(count);
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

/// Wakes every AP; each runs the registered AP handler (or parks if none).
pub fn startAps() bool {
    return releaseAps(0) != 0;
}

/// Publishes the job word and the entry point for every non-BSP CPU.
fn releaseAps(magic: u64) usize {
    const mp = limine.mp() orelse return 0;
    const cpus = mp.cpus orelse return 0;
    if (mp.cpu_count > percpu.max_cpus) return 0;
    const count: usize = @intCast(mp.cpu_count);
    const entry: *const fn (*limine.MpInfo) callconv(.c) void = @ptrCast(&apEntry);
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (cpus[index].lapic_id == mp.bsp_lapic_id) continue;
        // Publish the job before the release store that wakes the AP.
        cpus[index].extra_argument = magic;
        @atomicStore(@TypeOf(cpus[index].goto_address), &cpus[index].goto_address, entry, .release);
    }
    return count;
}

/// Releases every AP, runs the concurrent allocator stress on all CPUs, and
/// waits for them to report online. Smoke path.
pub fn run() bool {
    const console = serial.console;
    const mp = limine.mp() orelse return false;
    const cpus = mp.cpus orelse return false;

    // M2 tracks a bounded CPU count; the smoke machine must fit.
    if (mp.cpu_count > percpu.max_cpus) return false;
    const count: usize = @intCast(mp.cpu_count);

    const memmap = limine.memmap() orelse return false;
    frame.init(memmap);

    stress_done = 0;
    stress_errors = 0;
    const frames_before = frame.freeCount();

    if (releaseAps(stress_magic) == 0) return false;

    stressWorker();
    const deadline = cpu.rdtsc() + ap_timeout_ticks;
    while (@atomicLoad(u32, &stress_done, .acquire) != count) {
        if (cpu.rdtsc() > deadline) {
            console.write("SMP: timeout with ");
            format.writeDec(console, @atomicLoad(u32, &stress_done, .monotonic));
            console.write(" of ");
            format.writeDec(console, count);
            console.write(" stress workers done\n");
            return false;
        }
        cpu.pause();
    }
    if (@atomicLoad(u32, &stress_errors, .monotonic) != 0) {
        console.write("SMP: stress allocation errors\n");
        return false;
    }
    const frames_after = frame.freeCount();
    if (frames_after != frames_before) {
        console.write("SMP: frame count ");
        format.writeDec(console, frames_before);
        console.write(" -> ");
        format.writeDec(console, frames_after);
        console.write("\n");
        return false;
    }
    console.write("SMP: alloc stress ok\n");

    // Each block proves its own CPU filled it: self/index/apic_id only become
    // visible through the release store that also published `online`.
    var index: usize = 0;
    while (index < count) : (index += 1) {
        const block = percpu.at(index);
        if (!percpu.isOnline(block) or
            block.self != block or
            block.index != @as(u32, @intCast(index)) or
            block.apic_id != cpus[index].lapic_id)
        {
            console.write("SMP: bad per-CPU block at ");
            format.writeDec(console, index);
            console.write("\n");
            return false;
        }

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

/// Allocates and frees frames in batches; every CPU runs this at once.
fn stressWorker() void {
    var batch: [stress_batch]u64 = undefined;
    var iterations: u64 = 0;
    outer: while (iterations < stress_iterations) : (iterations += 1) {
        var taken: usize = 0;
        while (taken < stress_batch) : (taken += 1) {
            batch[taken] = frame.allocFrame() orelse {
                _ = @atomicRmw(u32, &stress_errors, .Add, 1, .monotonic);
                const console = serial.console;
                console.write("SMP: stress alloc failed on cpu ");
                format.writeDec(console, percpu.current().index);
                console.write(" at ");
                format.writeDec(console, iterations);
                console.write(", free ");
                format.writeDec(console, frame.freeCount());
                console.write("\n");
                break :outer;
            };
        }
        for (batch) |phys| frame.freeFrame(phys);
    }
    _ = @atomicRmw(u32, &stress_done, .Add, 1, .release);
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
        \\ andq $-16, %%rsp
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
    if (info.extra_argument == stress_magic) stressWorker();
    if (ap_handler) |handler| handler();
    park();
}

fn park() noreturn {
    while (true) {
        // SAFETY: parked AP with interrupts disabled; NMI/reset may wake it.
        asm volatile ("cli\n\thlt");
    }
}
