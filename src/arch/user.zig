//! User address spaces and the untrusted-pointer boundary. User pages are
//! W^X; every user memory access goes through copyFromUser/copyToUser.

const frame = @import("frame.zig");
const limine = @import("limine.zig");
const paging = @import("paging.zig");
const serial = @import("serial.zig");

pub const user_base: u64 = 0x0000_0000_0040_0000;
pub const user_limit: u64 = 0x0000_0100_0000_0000; // 4 GiB

pub const AddressSpace = struct {
    pml4: u64,
};

pub fn create() ?AddressSpace {
    // M2 user spaces are 4-level only; QEMU targets run 4-level paging.
    if (paging.isFiveLevel()) return null;
    const pml4 = frame.allocFrame() orelse return null;
    if (!paging.copyKernelEntries(pml4)) return null;
    return .{ .pml4 = pml4 };
}

/// Maps one zeroed 4 KiB page at `virt`. W^X is enforced.
pub fn mapUser(space: AddressSpace, virt: u64, writable: bool, executable: bool) bool {
    if (writable and executable) return false;
    if (virt < user_base or virt >= user_limit or (virt & 0xfff) != 0) return false;
    const hhdm = paging.hhdmOffset();
    const phys = frame.allocFrame() orelse return false;
    // SAFETY: the frame is RAM reachable through the HHDM.
    const page: [*]u8 = @ptrFromInt(hhdm + phys);
    @memset(page[0..4096], 0);

    var flags: u64 = paging.flags_user | paging.flags_nx;
    if (writable) flags |= paging.flags_rw;
    if (executable) flags &= ~paging.flags_nx;
    if (!paging.mapPageIn(space.pml4, virt, phys, flags)) {
        frame.freeFrame(phys);
        return false;
    }
    return true;
}

/// Copies from a user pointer; false on any invalid page, permission, or
/// range violation. Never faults on user input.
pub fn copyFromUser(space: AddressSpace, dst: []u8, src: u64) bool {
    if (!rangeOk(src, dst.len)) return false;
    const hhdm = paging.hhdmOffset();
    var done: usize = 0;
    while (done < dst.len) {
        const virt = src + done;
        const offset: usize = @intCast(virt & 0xfff);
        const chunk = @min(dst.len - done, 4096 - offset);
        const pte = paging.pteIn(space.pml4, virt) orelse return false;
        if ((pte & paging.flags_user) == 0) return false;
        const phys = paging.physFromPte(pte) + offset;
        // SAFETY: the PTE maps a RAM frame; the HHDM makes it readable.
        const page: [*]const u8 = @ptrFromInt(hhdm + phys);
        @memcpy(dst[done .. done + chunk], page[0..chunk]);
        done += chunk;
    }
    return true;
}

/// Copies into a user pointer; requires user-writable pages.
pub fn copyToUser(space: AddressSpace, dst: u64, src: []const u8) bool {
    if (!rangeOk(dst, src.len)) return false;
    const hhdm = paging.hhdmOffset();
    var done: usize = 0;
    while (done < src.len) {
        const virt = dst + done;
        const offset: usize = @intCast(virt & 0xfff);
        const chunk = @min(src.len - done, 4096 - offset);
        const pte = paging.pteIn(space.pml4, virt) orelse return false;
        if ((pte & paging.flags_user) == 0) return false;
        if ((pte & paging.flags_rw) == 0) return false;
        const phys = paging.physFromPte(pte) + offset;
        // SAFETY: the PTE is user-writable and points at a RAM frame.
        const page: [*]u8 = @ptrFromInt(hhdm + phys);
        @memcpy(page[0..chunk], src[done .. done + chunk]);
        done += chunk;
    }
    return true;
}

fn rangeOk(ptr: u64, len: usize) bool {
    const end = ptr +% @as(u64, len);
    if (end < ptr) return false;
    return ptr >= user_base and end <= user_limit;
}

pub fn runSmoke() bool {
    const console = serial.console;
    const hhdm = limine.hhdmOffset() orelse return false;
    const memmap = limine.memmap() orelse return false;
    frame.init(memmap);
    paging.init(hhdm);

    const space = create() orelse return false;

    if (!mapUser(space, user_base, true, false)) return false;
    if (!mapUser(space, user_base + 0x1000, false, false)) return false;
    if (!mapUser(space, user_base + 0x2000, false, true)) return false;
    if (mapUser(space, user_base + 0x3000, true, true)) return false;
    if (mapUser(space, user_base - 0x1000, false, false)) return false;
    console.write("USER: wx ok\n");

    if (rangeOk(user_base - 1, 1) or rangeOk(user_limit, 1)) return false;
    if (rangeOk(0xffff_ffff_ffff_ffff, 2)) return false;
    console.write("USER: ranges ok\n");

    const msg = "hello user";
    if (!copyToUser(space, user_base, msg)) return false;
    var buf: [msg.len]u8 = undefined;
    if (!copyFromUser(space, &buf, user_base)) return false;
    var same = true;
    for (msg, buf) |want, got| same = same and want == got;
    if (!same) return false;

    var ro: [4]u8 = undefined;
    if (!copyFromUser(space, &ro, user_base + 0x1000)) return false;
    if (copyToUser(space, user_base + 0x1000, msg)) return false;
    if (copyFromUser(space, &buf, user_base + 0x9000)) return false;
    if (copyFromUser(space, &buf, 0xffff_ffff_8000_0000)) return false;
    console.write("USER: copy ok\n");
    return true;
}
