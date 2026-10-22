//! Deterministic microbenchmarks for the kernel-bench variant. The harness
//! (tests/qemu-bench.sh) boots this under QEMU's icount mode, where the TSC
//! follows virtual time, so the printed cycle counts are a deterministic
//! function of the executed work. See docs/adr/0009.

const format = @import("../lib/interface.zig").format;
const frame = @import("frame.zig");
const heap = @import("heap.zig");
const limine = @import("limine.zig");
const paging = @import("paging.zig");
const serial = @import("serial.zig");

const frame_batch: usize = 32;
const frame_iterations: u64 = 2048;
const heap_iterations: u64 = 8192;
const heap_warmup: u64 = 64;
const heap_block: usize = 64;
const fault_pages: usize = 128;

var frame_scratch: [frame_batch]u64 = undefined;

pub fn run() bool {
    const hhdm = limine.hhdmOffset() orelse return false;
    const memmap = limine.memmap() orelse return false;
    frame.init(memmap);
    paging.init(hhdm);

    if (!frameChurn()) return false;
    if (!heapChurn()) return false;
    if (!demandFault()) return false;
    return true;
}

/// Frame allocator steady state: take a batch, give it back.
fn frameChurn() bool {
    const t0 = rdtsc();
    var iterations: u64 = 0;
    while (iterations < frame_iterations) : (iterations += 1) {
        for (&frame_scratch) |*slot| {
            slot.* = frame.allocFrame() orelse return false;
        }
        for (frame_scratch) |phys| frame.freeFrame(phys);
    }
    print("frame_churn", rdtsc() - t0, frame_iterations * frame_batch);
    return true;
}

/// Heap steady state: one block cycles through the free list.
fn heapChurn() bool {
    const kh = heap.kernel();

    // The first touches map the block's page on demand.
    var warmup: u64 = 0;
    while (warmup < heap_warmup) : (warmup += 1) {
        const block = kh.alloc(heap_block) orelse return false;
        block[0] = 0xab;
        kh.free(block);
    }

    const t0 = rdtsc();
    var iterations: u64 = 0;
    while (iterations < heap_iterations) : (iterations += 1) {
        const block = kh.alloc(heap_block) orelse return false;
        block[0] = @truncate(iterations);
        kh.free(block);
    }
    print("heap_churn", rdtsc() - t0, heap_iterations);
    return true;
}

/// Demand paging end to end: first touch of a fresh 512 KiB block.
fn demandFault() bool {
    const kh = heap.kernel();
    const bytes = kh.alloc(fault_pages * 4096) orelse return false;

    const before = paging.demandFaults();
    const t0 = rdtsc();
    var i: usize = 0;
    while (i < fault_pages) : (i += 1) {
        bytes[i * 4096] = @truncate(i);
    }
    const cycles = rdtsc() - t0;

    const faults = paging.demandFaults() - before;
    if (faults == 0) return false;
    print("demand_fault", cycles, faults);
    return true;
}

fn print(name: []const u8, cycles: u64, ops: u64) void {
    const console = serial.console;
    console.write("BENCH ");
    console.write(name);
    console.write(" ");
    format.writeDec(console, cycles);
    console.write(" ");
    format.writeDec(console, ops);
    console.write("\n");
}

fn rdtsc() u64 {
    var low: u32 = undefined;
    var high: u32 = undefined;
    // SAFETY: rdtsc is unprivileged; lfence keeps it from being speculated
    // ahead of the work that was just measured.
    asm volatile ("lfence\n\trdtsc"
        : [low] "={eax}" (low),
          [high] "={edx}" (high),
        :
        : .{ .memory = true });
    return (@as(u64, high) << 32) | low;
}
