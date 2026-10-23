//! Kernel GDT with user segments and per-CPU TSS/IST. Built once at boot;
//! each CPU loads the GDT and its own TSS selector, because the processor
//! marks the descriptor it loads busy and a second LTR on the same descriptor
//! faults.

const percpu = @import("percpu.zig");

// Layout: null, kernel code/data, user data/code, then two entries per CPU.
pub const kernel_cs: u16 = 0x08;
pub const kernel_ds: u16 = 0x10;
pub const user_ds: u16 = 0x18;
pub const user_cs: u16 = 0x20;
pub const tss_selector_base: u16 = 0x28;

pub const ist_double_fault: u8 = 1;
pub const ist_nmi: u8 = 2;
pub const ist_machine_check: u8 = 3;

// x86_64 TSS offsets from the Intel SDM: reserved0 at 0, rsp0 at 4,
// IST1..IST7 at 36..92, iomap_base at 102.
const tss_size = 104;
const tss_rsp0 = 4;
const tss_ist1 = 36;
const tss_ist2 = 44;
const tss_ist3 = 52;
const tss_iomap = 102;

const ist_stack_size = 16 * 1024;
const kernel_stack_size = 16 * 1024;
const gdt_entries = 5 + 2 * percpu.max_cpus;

extern fn loadGdtAndTss(gdtr: *const [10]u8, tss_selector: u16) void;

var gdt: [gdt_entries]u64 align(16) = undefined;
var gdtr: [10]u8 align(1) = undefined;
var tsses: [percpu.max_cpus][tss_size]u8 align(16) = undefined;

var kernel_stacks: [percpu.max_cpus][kernel_stack_size]u8 align(16) = undefined;
var double_fault_stacks: [percpu.max_cpus][ist_stack_size]u8 align(16) = undefined;
var nmi_stacks: [percpu.max_cpus][ist_stack_size]u8 align(16) = undefined;
var machine_check_stacks: [percpu.max_cpus][ist_stack_size]u8 align(16) = undefined;

pub fn init() void {
    gdt[0] = 0;
    gdt[1] = 0x00AF9A000000FFFF; // 64-bit kernel code, DPL0
    gdt[2] = 0x00CF92000000FFFF; // kernel data, DPL0
    gdt[3] = 0x00CFF2000000FFFF; // user data, DPL3
    gdt[4] = 0x00AFFA000000FFFF; // 64-bit user code, DPL3

    for (0..percpu.max_cpus) |cpu| {
        const tss = &tsses[cpu];
        @memset(tss[0..], 0);
        const kernel_top = @intFromPtr(&kernel_stacks[cpu]) + kernel_stack_size;
        const df_top = @intFromPtr(&double_fault_stacks[cpu]) + ist_stack_size;
        const nmi_top = @intFromPtr(&nmi_stacks[cpu]) + ist_stack_size;
        const mc_top = @intFromPtr(&machine_check_stacks[cpu]) + ist_stack_size;
        writeU64(tss[0..], tss_rsp0, @intCast(kernel_top));
        writeU64(tss[0..], tss_ist1, @intCast(df_top));
        writeU64(tss[0..], tss_ist2, @intCast(nmi_top));
        writeU64(tss[0..], tss_ist3, @intCast(mc_top));
        writeU16(tss[0..], tss_iomap, tss_size);

        const base: u64 = @intFromPtr(tss);
        const limit: u64 = tss.len - 1;
        gdt[5 + 2 * cpu] = (limit & 0xFFFF) |
            ((base & 0xFFFFFF) << 16) |
            (@as(u64, 0x89) << 40) |
            (((limit >> 16) & 0xF) << 48) |
            (((base >> 24) & 0xFF) << 56);
        gdt[6 + 2 * cpu] = (base >> 32) & 0xFFFFFFFF;
    }

    const limit16: u16 = @intCast(@sizeOf(@TypeOf(gdt)) - 1);
    const base64: u64 = @intFromPtr(&gdt);
    gdtr[0] = @truncate(limit16);
    gdtr[1] = @truncate(limit16 >> 8);
    gdtr[2] = @truncate(base64);
    gdtr[3] = @truncate(base64 >> 8);
    gdtr[4] = @truncate(base64 >> 16);
    gdtr[5] = @truncate(base64 >> 24);
    gdtr[6] = @truncate(base64 >> 32);
    gdtr[7] = @truncate(base64 >> 40);
    gdtr[8] = @truncate(base64 >> 48);
    gdtr[9] = @truncate(base64 >> 56);

    load();
}

/// Loads the GDT and this CPU's TSS. Requires percpu.setup() to have run.
pub fn load() void {
    const selector: u16 = tss_selector_base + @as(u16, @intCast(percpu.current().index)) * 0x10;
    const gdtr_ptr: *align(1) const [10]u8 = &gdtr;
    loadGdtAndTss(gdtr_ptr, selector);
    const cpu = percpu.current().index;
    percpu.setEntryStack(@intFromPtr(&kernel_stacks[cpu]) + kernel_stack_size);
}

pub fn isInIstStack(index: u8, rsp: usize) bool {
    const cpu = percpu.current().index;
    const Range = struct { base: usize, len: usize };
    const range: Range = switch (index) {
        ist_double_fault => .{
            .base = @intFromPtr(&double_fault_stacks[cpu]),
            .len = ist_stack_size,
        },
        ist_nmi => .{
            .base = @intFromPtr(&nmi_stacks[cpu]),
            .len = ist_stack_size,
        },
        ist_machine_check => .{
            .base = @intFromPtr(&machine_check_stacks[cpu]),
            .len = ist_stack_size,
        },
        else => return false,
    };
    return rsp >= range.base and rsp < range.base + range.len;
}

fn writeU16(buf: []u8, offset: usize, value: u16) void {
    buf[offset] = @truncate(value);
    buf[offset + 1] = @truncate(value >> 8);
}

fn writeU64(buf: []u8, offset: usize, value: u64) void {
    var v = value;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        buf[offset + i] = @truncate(v);
        v >>= 8;
    }
}
