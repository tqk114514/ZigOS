//! M1 memory smoke: HHDM/memmap, frame allocator, page mapping, kernel heap,
//! demand paging, and the exhaustion/recovery pressure checks.

const format = @import("../lib/interface.zig").format;
const frame = @import("frame.zig");
const heap = @import("heap.zig");
const limine = @import("limine.zig");
const paging = @import("paging.zig");
const serial = @import("serial.zig");

const test_virt: u64 = 0xffff_9000_0000_0000;
const frame_mask: u64 = 0x000F_FFFF_FFFF_F000;

// Addresses taken during the pressure phases, so every one can be handed back.
// Bounded by the largest exhaustible set: 512MiB of free frames plus margin.
var pressure_slots: [1 << 18]u64 = undefined;

pub fn run() bool {
    const console = serial.console;

    const hhdm = limine.hhdmOffset() orelse {
        console.write("MEM: no HHDM\n");
        return false;
    };
    const memmap = limine.memmap() orelse {
        console.write("MEM: no memmap\n");
        return false;
    };

    frame.init(memmap);
    paging.init(hhdm);

    console.write("MEM: levels ");
    format.writeDec(console, @as(u64, if (paging.isFiveLevel()) 5 else 4));
    console.write(", frames ");
    format.writeDec(console, frame.totalCount());
    console.write(" total, ");
    format.writeDec(console, frame.freeCount());
    console.write(" free\n");

    const f1 = frame.allocFrame() orelse return false;
    // SAFETY: the frame is RAM, reachable as HHDM + physical; 8-byte aligned.
    const p1: *u64 = @ptrFromInt(hhdm + f1);
    p1.* = 0xdead_beef;
    if (p1.* != 0xdead_beef) return false;
    frame.freeFrame(f1);

    const f2 = frame.allocFrame() orelse return false;
    if (!paging.mapPage(test_virt, f2, paging.flags_rw | paging.flags_nx)) return false;
    // SAFETY: test_virt was just mapped to an 8-byte-aligned RAM frame.
    const vp: *u64 = @ptrFromInt(test_virt);
    vp.* = 0xfeed_face;
    if (vp.* != 0xfeed_face) return false;

    const back = paging.translate(test_virt) orelse return false;
    if ((back & frame_mask) != (f2 & frame_mask)) return false;

    // Kernel heap over an initially unmapped range; the first writes fault
    // and the page-fault handler maps the heap pages on demand.
    const kh = heap.kernel();
    const a = kh.alloc(32) orelse return false;
    a[0] = 1;
    a[31] = 2;
    if (a[0] != 1 or a[31] != 2) return false;
    const a_ptr = @intFromPtr(a.ptr);
    kh.free(a);

    const b = kh.alloc(32) orelse return false;
    if (@intFromPtr(b.ptr) != a_ptr) return false;
    b[0] = 5;
    if (b[0] != 5) return false;

    const big = kh.alloc(8192) orelse return false;
    big[0] = 7;
    big[8191] = 9;
    if (big[0] != 7 or big[8191] != 9) return false;

    const stats = heap.stats();
    if (stats.live_blocks < 2) return false;
    if (stats.live_bytes == 0 or stats.live_bytes > stats.capacity_bytes) return false;

    // Keep the faulting heap writes ordered before the effect checks below.
    asm volatile ("" ::: .{ .memory = true });
    const faults = paging.demandFaults();
    if (faults == 0) return false;
    if (paging.translate(a_ptr) == null) return false;

    console.write("MEM: heap faults ");
    format.writeDec(console, faults);
    console.write(" head ");
    format.writeHex(console, a_ptr, 16);
    console.write("\n");

    console.write("MEM: mapped ");
    format.writeHex(console, test_virt, 16);
    console.write(" -> ");
    format.writeHex(console, f2, 16);
    console.write("\n");

    if (!framePressure()) return false;

    const before_pressure = heap.stats();
    if (!heapPressure()) return false;
    const after_pressure = heap.stats();
    if (after_pressure.live_blocks != before_pressure.live_blocks) return false;
    if (after_pressure.live_bytes != before_pressure.live_bytes) return false;
    return true;
}

/// Exhausts the heap bump range, then frees everything back and proves the
/// whole range is reusable again. Runs after the frame phase: block-header
/// writes demand-map every heap page, which consumes frames as it goes.
fn heapPressure() bool {
    const kh = heap.kernel();

    var blocks: usize = 0;
    while (blocks < pressure_slots.len) {
        const block = kh.alloc(4096) orelse break;
        pressure_slots[blocks] = @intFromPtr(block.ptr);
        blocks += 1;
    }
    // An exhausted heap must refuse a bigger request; running out of scratch
    // slots first would mean the heap range outgrew the smoke.
    if (blocks == pressure_slots.len) return false;
    if (kh.alloc(8192) != null) return false;

    var i = blocks;
    while (i > 0) {
        i -= 1;
        // SAFETY: the slot holds a payload pointer returned by this heap.
        const ptr: [*]u8 = @ptrFromInt(pressure_slots[i]);
        kh.free(ptr[0..4096]);
    }

    // First-fit serves the most recently freed head.
    const reuse = kh.alloc(4096) orelse return false;
    if (@intFromPtr(reuse.ptr) != pressure_slots[0]) return false;
    kh.free(reuse);

    serial.console.write("MEM: heap pressure ");
    format.writeDec(serial.console, blocks);
    serial.console.write(" blocks\n");
    return true;
}

/// Exhausts the frame allocator (the accounting must hit exactly zero), frees
/// everything back, and checks the double-free guard.
fn framePressure() bool {
    const before = frame.freeCount();

    var taken: usize = 0;
    var exhausted = false;
    while (taken < pressure_slots.len) {
        const phys = frame.allocFrame() orelse {
            exhausted = true;
            break;
        };
        pressure_slots[taken] = phys;
        taken += 1;
    }
    if (exhausted) {
        if (frame.freeCount() != 0) return false;
        if (frame.allocFrame() != null) return false;
    } else if (frame.freeCount() != before - taken) {
        return false;
    }

    var i = taken;
    while (i > 0) {
        i -= 1;
        frame.freeFrame(pressure_slots[i]);
    }
    if (frame.freeCount() != before) return false;

    // A double free must not double-count.
    const again = frame.allocFrame() orelse return false;
    frame.freeFrame(again);
    const restored = frame.freeCount();
    frame.freeFrame(again);
    if (frame.freeCount() != restored) return false;

    serial.console.write("MEM: frames ");
    serial.console.write(if (exhausted) "exhausted " else "partial ");
    format.writeDec(serial.console, taken);
    serial.console.write("\n");
    return true;
}
