//! Per-CPU data, addressed through the GS base MSR. The static array covers
//! the boot-time CPU count; each CPU writes only its own entry, and `online`
//! is the release/acquire handoff to the boot CPU.

const apic = @import("apic.zig");

pub const max_cpus: usize = 8;

const gs_base_msr = 0xc0000101;
const kernel_gs_base_msr = 0xc0000102;

pub const Cpu = extern struct {
    self: *Cpu,
    index: u32,
    apic_id: u32,
    online: u32,
    entry_rsp: u64,
    user_rsp: u64,
};

// syscall.S hard-codes these GS-relative offsets.
comptime {
    if (@offsetOf(Cpu, "entry_rsp") != 24) @compileError("syscall.S expects entry_rsp at gs:24");
    if (@offsetOf(Cpu, "user_rsp") != 32) @compileError("syscall.S expects user_rsp at gs:32");
}

// Boot-once state: entries are filled by their own CPU before `online`, and
// read by other CPUs only after acquiring `online`.
var cpus: [max_cpus]Cpu = undefined;
var cpu_count: usize = 1;

pub fn setCount(n: usize) void {
    cpu_count = n;
}

pub fn count() usize {
    return cpu_count;
}

/// Resets the online flags before any AP is released.
pub fn init() void {
    for (&cpus) |*entry| entry.online = 0;
}

pub fn at(index: usize) *Cpu {
    return &cpus[index];
}

/// Fills `cpus[index]` and points this CPU's GS base at it.
pub fn setup(index: usize, apic_id: u32) *Cpu {
    const entry = &cpus[index];
    entry.self = entry;
    entry.index = @intCast(index);
    entry.apic_id = apic_id;
    entry.entry_rsp = 0;
    entry.user_rsp = 0;
    apic.wrmsr(gs_base_msr, @intFromPtr(entry));
    // User GS starts empty; syscall entry swaps the two bases.
    apic.wrmsr(kernel_gs_base_msr, 0);
    return entry;
}

pub fn setEntryStack(top: usize) void {
    current().entry_rsp = top;
}

pub fn markOnline(entry: *Cpu) void {
    @atomicStore(u32, &entry.online, 1, .release);
}

pub fn isOnline(entry: *const Cpu) bool {
    return @atomicLoad(u32, &entry.online, .acquire) != 0;
}

/// The current CPU's block. The GS base is set by setup() via the MSR and
/// survives segment reloads because the loader never reloads the GS selector.
pub fn current() *Cpu {
    var entry: *Cpu = undefined;
    // SAFETY: GS points at this CPU's Cpu block (set by setup()).
    asm volatile ("movq %%gs:0, %[out]"
        : [out] "=r" (entry),
    );
    return entry;
}
