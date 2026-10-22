//! Kernel GDT, per-CPU TSS descriptors, and IST stacks. Built once at boot;
//! each CPU loads the GDT and its own TSS selector, because the processor
//! marks the descriptor it loads busy and a second LTR on the same descriptor
//! faults.

const percpu = @import("percpu.zig");

pub const tss_selector_base: u16 = 0x18;

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

const gdt_entries = 3 + 2 * percpu.max_cpus;

extern var __stack_top: u8;
extern fn loadGdtAndTss(gdtr: *const [10]u8, tss_selector: u16) void;

var gdt: [gdt_entries]u64 align(16) = undefined;
var gdtr: [10]u8 align(1) = undefined;
var tss: [tss_size]u8 align(16) = undefined;

var double_fault_stack: [16 * 1024]u8 align(16) = undefined;
var nmi_stack: [16 * 1024]u8 align(16) = undefined;
var machine_check_stack: [16 * 1024]u8 align(16) = undefined;

pub fn init() void {
    @memset(tss[0..], 0);
    const kernel_stack_top = @intFromPtr(&__stack_top);
    const df_top = @intFromPtr(&double_fault_stack) + double_fault_stack.len;
    const nmi_top = @intFromPtr(&nmi_stack) + nmi_stack.len;
    const mc_top = @intFromPtr(&machine_check_stack) + machine_check_stack.len;

    writeU64(tss[0..], tss_rsp0, @intCast(kernel_stack_top));
    writeU64(tss[0..], tss_ist1, @intCast(df_top));
    writeU64(tss[0..], tss_ist2, @intCast(nmi_top));
    writeU64(tss[0..], tss_ist3, @intCast(mc_top));
    writeU16(tss[0..], tss_iomap, tss_size);

    gdt[0] = 0;
    gdt[1] = 0x00AF9A000000FFFF; // 64-bit kernel code, DPL0
    gdt[2] = 0x00CF92000000FFFF; // kernel data, DPL0

    const tss_base: u64 = @intFromPtr(&tss);
    const tss_limit: u64 = tss.len - 1;
    const tss_low = (tss_limit & 0xFFFF) |
        ((tss_base & 0xFFFFFF) << 16) |
        (@as(u64, 0x89) << 40) |
        (((tss_limit >> 16) & 0xF) << 48) |
        (((tss_base >> 24) & 0xFF) << 56);
    const tss_high = (tss_base >> 32) & 0xFFFFFFFF;
    // One descriptor per CPU; LTR sets the busy bit on the descriptor it uses.
    for (0..percpu.max_cpus) |i| {
        gdt[3 + 2 * i] = tss_low;
        gdt[4 + 2 * i] = tss_high;
    }

    const limit: u16 = @intCast(@sizeOf(@TypeOf(gdt)) - 1);
    const base: u64 = @intFromPtr(&gdt);
    gdtr[0] = @truncate(limit);
    gdtr[1] = @truncate(limit >> 8);
    gdtr[2] = @truncate(base);
    gdtr[3] = @truncate(base >> 8);
    gdtr[4] = @truncate(base >> 16);
    gdtr[5] = @truncate(base >> 24);
    gdtr[6] = @truncate(base >> 32);
    gdtr[7] = @truncate(base >> 40);
    gdtr[8] = @truncate(base >> 48);
    gdtr[9] = @truncate(base >> 56);

    load();
}

/// Loads the GDT and this CPU's TSS. Requires percpu.setup() to have run.
pub fn load() void {
    const selector: u16 = tss_selector_base + @as(u16, @intCast(percpu.current().index)) * 0x10;
    const gdtr_ptr: *align(1) const [10]u8 = &gdtr;
    loadGdtAndTss(gdtr_ptr, selector);
}

pub fn isInIstStack(index: u8, rsp: usize) bool {
    const Range = struct { base: usize, len: usize };
    const range: Range = switch (index) {
        ist_double_fault => .{
            .base = @intFromPtr(&double_fault_stack),
            .len = double_fault_stack.len,
        },
        ist_nmi => .{
            .base = @intFromPtr(&nmi_stack),
            .len = nmi_stack.len,
        },
        ist_machine_check => .{
            .base = @intFromPtr(&machine_check_stack),
            .len = machine_check_stack.len,
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
