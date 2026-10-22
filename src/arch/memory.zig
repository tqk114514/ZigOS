//! M1 memory smoke: HHDM/memmap, frame allocator, and one page mapping.

const format = @import("../lib/interface.zig").format;
const frame = @import("frame.zig");
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

    console.write("MEM: mapped ");
    format.writeHex(console, test_virt, 16);
    console.write(" -> ");
    format.writeHex(console, f2, 16);
    console.write("\n");
    return true;
}
