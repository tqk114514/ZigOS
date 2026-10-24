//! IDT, fatal exception entry, and the returnable-IRQ dispatch. The IDT is
//! populated once at boot and then only read by software; hardware reads it
//! via lidt.

const format = @import("../lib/interface.zig").format;
const extirq = @import("extirq.zig");
const gdt = @import("gdt.zig");
const paging = @import("paging.zig");
const port = @import("port.zig");
const serial = @import("serial.zig");
const timer = @import("timer.zig");

const isr_count: usize = 32;
const irq_count: usize = 16;
const idt_entries: usize = 256;

const IdtEntry = extern struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8,
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,
};

const ExceptionFrame = extern struct {
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

extern const isr_stub_table: [isr_count]u64;
extern const irq_stub_table: [irq_count]u64;
extern fn pf_stub() callconv(.c) void;
extern fn irq_ext() callconv(.c) void;
extern fn irq_ipi() callconv(.c) void;
extern fn irq_tlb() callconv(.c) void;

pub const timer_vector: u64 = 32;
pub const ipi_vector: u64 = 50;
pub const tlb_vector: u64 = 51;

pub const VectorHandler = *const fn () callconv(.c) void;

// Boot-once registration: the kernel wires handlers before interrupts are
// enabled; afterwards the table and hooks are read-only.
var vector_handlers: [idt_entries]?VectorHandler = nullArray(idt_entries);
var preempt_hook: ?VectorHandler = null;

fn nullArray(comptime n: usize) [n]?VectorHandler {
    var out: [n]?VectorHandler = undefined;
    for (&out) |*slot| slot.* = null;
    return out;
}

pub fn setVectorHandler(vector: u8, handler: ?VectorHandler) void {
    vector_handlers[vector] = handler;
}

pub fn setPreemptHook(hook: ?VectorHandler) void {
    preempt_hook = hook;
}

var idt: [idt_entries]IdtEntry align(16) = undefined;
var idtr: [10]u8 align(1) = undefined;

pub fn init() void {
    const cs = currentCs();
    for (&idt) |*entry| {
        entry.* = .{
            .offset_low = 0,
            .selector = 0,
            .ist = 0,
            .type_attr = 0,
            .offset_mid = 0,
            .offset_high = 0,
            .reserved = 0,
        };
    }
    for (0..isr_count) |i| {
        idt[i] = makeEntry(isr_stub_table[i], cs, istIndex(i));
    }
    for (0..irq_count) |i| {
        idt[32 + i] = makeEntry(irq_stub_table[i], cs, 0);
    }
    // Vector 14 uses the returnable page-fault stub instead of the fatal one.
    idt[14] = makeEntry(@intCast(@intFromPtr(&pf_stub)), cs, 0);
    // The external IRQ stub sits outside the 16 IRQ-stub vectors.
    idt[extirq.vector] = makeEntry(@intCast(@intFromPtr(&irq_ext)), cs, 0);
    idt[ipi_vector] = makeEntry(@intCast(@intFromPtr(&irq_ipi)), cs, 0);
    idt[tlb_vector] = makeEntry(@intCast(@intFromPtr(&irq_tlb)), cs, 0);

    // lidt consumes a packed 10-byte descriptor (u16 limit, u64 base). Build it
    // as bytes so the inline asm memory operand cannot pick up struct padding.
    const limit: u16 = @intCast(@sizeOf(@TypeOf(idt)) - 1);
    const base: u64 = @intFromPtr(&idt);
    idtr[0] = @truncate(limit);
    idtr[1] = @truncate(limit >> 8);
    idtr[2] = @truncate(base);
    idtr[3] = @truncate(base >> 8);
    idtr[4] = @truncate(base >> 16);
    idtr[5] = @truncate(base >> 24);
    idtr[6] = @truncate(base >> 32);
    idtr[7] = @truncate(base >> 40);
    idtr[8] = @truncate(base >> 48);
    idtr[9] = @truncate(base >> 56);

    load();
}

/// Loads the built IDT on the current CPU.
pub fn load() void {
    const idtr_ptr: *align(1) const [10]u8 = &idtr;
    // SAFETY: the IDT is fully populated and 16-byte aligned; lidt is privileged.
    asm volatile ("lidt (%[ptr])"
        :
        : [ptr] "r" (idtr_ptr),
        : .{ .memory = true });
}

fn directionFlagSet() bool {
    const flags = asm volatile ("pushfq\n\tpopq %[out]"
        : [out] "=r" (-> u64),
    );
    return (flags & (1 << 10)) != 0;
}

fn abortEntry() noreturn {
    serial.console.write("\nKERNEL: direction flag set at entry\n");
    while (true) {
        // SAFETY: fatal invariant; stop this CPU with interrupts disabled.
        asm volatile ("cli\n\thlt");
    }
}

export fn irqHandler(vector: u64) callconv(.c) void {
    if (directionFlagSet()) abortEntry();
    if (vector < idt_entries) {
        if (vector_handlers[@intCast(vector)]) |handler| {
            handler();
            return;
        }
    }
    switch (vector) {
        timer_vector => timer.handleIrq(),
        extirq.vector => extirq.handleIrq(),
        else => {},
    }
}

/// Called by irq_common right before restoring the interrupted context.
export fn irqPreemptCheck() callconv(.c) void {
    if (preempt_hook) |hook| hook();
}

export fn pageFaultHandler(frame: *const ExceptionFrame) callconv(.c) bool {
    if (directionFlagSet()) abortEntry();
    return paging.handlePageFault(frame.error_code);
}

export fn exceptionHandler(frame: *const ExceptionFrame) callconv(.c) noreturn {
    if (directionFlagSet()) abortEntry();
    const console = serial.console;
    // SAFETY: reading the current stack pointer in the exception handler.
    const current_rsp = asm volatile ("mov %%rsp, %[out]"
        : [out] "=r" (-> usize),
    );

    console.write("\nEXCEPTION ");
    format.writeDec(console, frame.vector);
    console.write(": ");
    console.write(exceptionName(frame.vector));
    console.write("\n  error: ");
    format.writeHex(console, frame.error_code, 16);
    console.write("\n  rip: ");
    format.writeHex(console, frame.rip, 16);
    console.write(" cs: ");
    format.writeHex(console, frame.cs, 4);
    console.write("\n  rflags: ");
    format.writeHex(console, frame.rflags, 16);
    console.write(" rsp: ");
    format.writeHex(console, frame.rsp, 16);
    console.write(" ss: ");
    format.writeHex(console, frame.ss, 4);
    console.write("\n");

    if (frame.vector == 2) {
        console.write("  ist: ");
        console.write(if (gdt.isInIstStack(gdt.ist_nmi, current_rsp)) "ok" else "bad");
        console.write("\n");
    }

    // QEMU isa-debug-exit: 0x12 -> 37, 0x13 -> 39.
    const exit_code: u8 = if (frame.vector == 2) 0x13 else 0x12;
    port.outb(0xf4, exit_code);
    while (true) {
        // SAFETY: fatal exception path; interrupts stay disabled.
        asm volatile ("cli\n\thlt");
    }
}

fn makeEntry(addr: u64, cs: u16, ist: u8) IdtEntry {
    return .{
        .offset_low = @truncate(addr),
        .selector = cs,
        .ist = ist,
        .type_attr = 0x8e,
        .offset_mid = @truncate(addr >> 16),
        .offset_high = @truncate(addr >> 32),
        .reserved = 0,
    };
}

fn istIndex(vector: usize) u8 {
    return switch (vector) {
        2 => gdt.ist_nmi,
        8 => gdt.ist_double_fault,
        18 => gdt.ist_machine_check,
        else => 0,
    };
}

fn currentCs() u16 {
    // SAFETY: reading the current code selector at CPL0.
    return asm volatile ("mov %%cs, %[out]"
        : [out] "=r" (-> u16),
    );
}

fn exceptionName(vector: u64) []const u8 {
    return switch (vector) {
        0 => "divide error",
        1 => "debug",
        2 => "non-maskable interrupt",
        3 => "breakpoint",
        4 => "overflow",
        5 => "bound range exceeded",
        6 => "invalid opcode",
        7 => "device not available",
        8 => "double fault",
        9 => "coprocessor segment overrun",
        10 => "invalid TSS",
        11 => "segment not present",
        12 => "stack-segment fault",
        13 => "general protection fault",
        14 => "page fault",
        15 => "reserved",
        16 => "x87 floating-point exception",
        17 => "alignment check",
        18 => "machine check",
        19 => "SIMD floating-point exception",
        20 => "virtualization exception",
        21 => "control protection exception",
        22...28 => "reserved",
        29 => "VMM communication exception",
        30 => "security exception",
        31 => "reserved",
        else => "unknown",
    };
}
