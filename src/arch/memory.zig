//! M1 memory smoke: HHDM/memmap, frame allocator, and one page mapping.

const format = @import("../lib/interface.zig").format;
const frame = @import("frame.zig");
const heap = @import("heap.zig");
const limine = @import("limine.zig");
const paging = @import("paging.zig");
const serial = @import("serial.zig");

const test_virt: u64 = 0xffff_9000_0000_0000;
const frame_mask: u64 = 0x000F_FFFF_FFFF_F000;

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
    console.write(", free frames ");
    format.writeDec(console, frame.freeCount());
    console.write("\n");

    const f1 = frame.allocFrame() orelse return false;
    const p1: *u64 = @ptrFromInt(hhdm + f1);
    p1.* = 0xdead_beef;
    if (p1.* != 0xdead_beef) return false;
    frame.freeFrame(f1);

    const f2 = frame.allocFrame() orelse return false;
    if (!paging.mapPage(test_virt, f2, paging.flags_rw | paging.flags_nx)) return false;
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
    return true;
}
