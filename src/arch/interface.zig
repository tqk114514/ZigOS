const hal = @import("../hal/interface.zig");
const port = @import("port.zig");
const serial = @import("serial.zig");
const apic = @import("apic.zig");
const context = @import("context.zig");
const cpu = @import("cpu.zig");
const limine = @import("limine.zig");
const percpu = @import("percpu.zig");
const spinlock = @import("spinlock.zig");
const backtrace = @import("backtrace.zig");
const bench = @import("bench.zig");
const exceptions = @import("exceptions.zig");
const extirq = @import("extirq.zig");
const gdt = @import("gdt.zig");
const memory = @import("memory.zig");
const smp = @import("smp.zig");
const timer = @import("timer.zig");
const tlb = @import("tlb.zig");
const syscall = @import("syscall.zig");
const user = @import("user.zig");

pub const serial_console = serial.console;
pub const Lock = spinlock.Lock;
pub const VectorHandler = exceptions.VectorHandler;
pub const cpu_limit: usize = percpu.max_cpus;
pub const timer_vector: u8 = @intCast(exceptions.timer_vector);
pub const ipi_vector: u8 = @intCast(exceptions.ipi_vector);

pub fn disableInterrupts() void {
    cpu.disableInterrupts();
}

pub fn initSerial() void {
    serial.init();
}

pub fn initGdt() void {
    gdt.init();
}

pub fn initIdt() void {
    exceptions.init();
}

pub fn initPerCpu() bool {
    return smp.initBsp();
}

pub fn runSmpSmoke() bool {
    return smp.run();
}

pub fn initTimer() void {
    timer.init();
}

pub fn runMemorySmoke() bool {
    return memory.run();
}

pub fn runExternalSmoke() bool {
    return extirq.run();
}

pub fn initSyscall() void {
    syscall.init();
}

pub fn setUserSpace(address_space: user.AddressSpace) void {
    syscall.setAddressSpace(address_space);
}

pub fn initTlb() void {
    tlb.init();
}

pub fn tlbProbe() bool {
    return tlb.probe();
}

pub fn runUserSmoke() bool {
    return user.runSmoke();
}

pub fn runBench() bool {
    return bench.run();
}

pub fn cpuIndex() usize {
    return percpu.current().index;
}

pub fn cpuCount() usize {
    return percpu.count();
}

pub fn apicIdOf(index: usize) u32 {
    return percpu.at(index).apic_id;
}

pub fn switchContext(save: *usize, next_rsp: usize) void {
    context.switchContext(save, next_rsp);
}

pub fn sendIpi(apic_id: u32, vector: u8) void {
    apic.sendIpi(apic_id, vector);
}

pub fn eoi() void {
    apic.eoi();
}

pub fn enableInterrupts() void {
    cpu.enableInterrupts();
}

pub fn saveAndDisableInterrupts() bool {
    return cpu.saveAndDisableInterrupts();
}

pub fn restoreInterrupts(enabled: bool) void {
    cpu.restoreInterrupts(enabled);
}

pub fn rdtsc() u64 {
    return cpu.rdtsc();
}

pub fn cpuPause() void {
    cpu.pause();
}

/// Enables x2APIC on this CPU and programs its periodic timer.
pub fn startLocalTimer() bool {
    if (!apic.hasX2Apic()) return false;
    apic.enable();
    timer.programPeriodic();
    return true;
}

pub fn setVectorHandler(vector: u8, handler: ?VectorHandler) void {
    exceptions.setVectorHandler(vector, handler);
}

pub fn setPreemptHook(hook: ?VectorHandler) void {
    exceptions.setPreemptHook(hook);
}

pub fn setApHandler(handler: ?*const fn () callconv(.c) noreturn) void {
    smp.setApHandler(handler);
}

pub fn startAps() bool {
    return smp.startAps();
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
