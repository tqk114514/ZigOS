//! User address spaces and the untrusted-pointer boundary. User pages are
//! W^X; every user memory access goes through copyFromUser/copyToUser.

const frame = @import("frame.zig");
const limine = @import("limine.zig");
const paging = @import("paging.zig");
const serial = @import("serial.zig");
const syscall = @import("syscall.zig");

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
pub fn mapUser(space: AddressSpace, virt: u64, writable: bool, executable: bool) ?u64 {
    if (writable and executable) return null;
    if (virt < user_base or virt >= user_limit or (virt & 0xfff) != 0) return null;
    const hhdm = paging.hhdmOffset();
    const phys = frame.allocFrame() orelse return null;
    // SAFETY: the frame is RAM reachable through the HHDM.
    const page: [*]u8 = @ptrFromInt(hhdm + phys);
    @memset(page[0..4096], 0);

    var flags: u64 = paging.flags_user | paging.flags_nx;
    if (writable) flags |= paging.flags_rw;
    if (executable) flags &= ~paging.flags_nx;
    if (!paging.mapPageIn(space.pml4, virt, phys, flags)) {
        frame.freeFrame(phys);
        return null;
    }
    return phys;
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

    if (mapUser(space, user_base, true, false) == null) return false;
    if (mapUser(space, user_base + 0x1000, false, false) == null) return false;
    if (mapUser(space, user_base + 0x2000, false, true) == null) return false;
    if (mapUser(space, user_base + 0x3000, true, true) != null) return false;
    if (mapUser(space, user_base - 0x1000, false, false) != null) return false;
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

    // Ring3: a hand-assembled program writes "USER OK" and exits.
    const code_phys = mapUser(space, user_code, false, true) orelse return false;
    const stack_phys = mapUser(space, user_stack, true, false) orelse return false;
    _ = stack_phys;
    const code: [*]u8 = @ptrFromInt(paging.hhdmOffset() + code_phys);
    const program = comptime buildProgram();
    @memcpy(code[0..program.len], &program);

    syscall.setAddressSpace(space);
    const status = syscall.runUser(user_code, user_stack + 0x1000 - 16);
    if (status != 0) return false;
    if (syscall.exitedWith()) |code_status| {
        if (code_status != 0) return false;
    } else return false;
    console.write("USER: ring3 ok\n");
    return true;
}

const user_stack: u64 = user_base + 0x1000;
const user_code: u64 = user_base + 0x3000;
const program_len: usize = 46;
const msg_offset: usize = 38;

fn buildProgram() [program_len]u8 {
    var out: [program_len]u8 = undefined;
    for (&out) |*b| b.* = 0;
    out[0] = 0xb8;
    out[1] = 1; // mov $1, %eax (write)
    out[5] = 0xbf;
    out[6] = 1; // mov $1, %edi (console handle)
    out[10] = 0x48;
    out[11] = 0xbe; // movabs $msg, %rsi
    var addr = user_code + msg_offset;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        out[12 + i] = @truncate(addr);
        addr >>= 8;
    }
    out[20] = 0xba;
    out[21] = 8; // mov $8, %edx
    out[25] = 0x0f;
    out[26] = 0x05; // syscall
    out[27] = 0xb8; // mov $0, %eax (exit)
    out[32] = 0x31;
    out[33] = 0xff; // xor %edi, %edi
    out[34] = 0x0f;
    out[35] = 0x05; // syscall
    out[36] = 0xeb;
    out[37] = 0xfe; // jmp . (fallback)
    const msg = "USER OK\n";
    for (msg, 0..) |c, j| out[msg_offset + j] = c;
    return out;
}
