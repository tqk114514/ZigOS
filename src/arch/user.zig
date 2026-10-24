//! User address spaces and the untrusted-pointer boundary. User pages are
//! W^X; every user memory access goes through copyFromUser/copyToUser.

const cpu = @import("cpu.zig");

var console_handle: u64 = 1;

/// Sets the handle value the embedded programs pass to write().
pub fn setConsoleHandle(handle: u64) void {
    console_handle = handle;
}
const frame = @import("frame.zig");
const tlb = @import("tlb.zig");
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
    if (console_handle > 0xff) return false;

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
    const program = buildProgram();
    @memcpy(code[0..program.len], &program);

    const status = syscall.runUser(space, user_code, user_stack + 0x1000 - 16);
    if (status != 0) return false;
    if (syscall.exitedWith()) |code_status| {
        if (code_status != 0) return false;
    } else return false;
    console.write("USER: ring3 ok\n");

    const spin_phys = mapUser(space, user_code2, false, true) orelse return false;
    const spin_code: [*]u8 = @ptrFromInt(paging.hhdmOffset() + spin_phys);
    const spin_program = buildSpinProgram();
    @memcpy(spin_code[0..spin_program.len], &spin_program);
    const spin_status = syscall.runUser(space, user_code2, user_stack + 0x1000 - 16);
    if (spin_status != 0) return false;
    if (syscall.exitedWith()) |code_status| {
        if (code_status != 0) return false;
    } else return false;
    console.write("USER: spin ok\n");
    return true;
}

const user_stack: u64 = user_base + 0x1000;
const user_code: u64 = user_base + 0x3000;
const user_code2: u64 = user_base + 0x4000;
const program_len: usize = 46;
const msg_offset: usize = 38;

const spin_program_len: usize = 58;
const spin_msg_offset: usize = 48;
const spin_iterations: u32 = 60_000_000;

fn buildSpinProgram() [spin_program_len]u8 {
    var out: [spin_program_len]u8 = undefined;
    for (&out) |*b| b.* = 0;
    out[0] = 0xfd; // std: a user may run with DF set; preemption must survive it
    out[1] = 0xb9; // mov $N, %ecx
    var n = spin_iterations;
    var i: usize = 0;
    while (i < 4) : (i += 1) {
        out[2 + i] = @truncate(n);
        n >>= 8;
    }
    out[6] = 0xff;
    out[7] = 0xc9; // dec %ecx
    out[8] = 0x75;
    out[9] = 0xfc; // jnz -4
    out[10] = 0xb8;
    out[11] = 1; // mov $1, %eax
    out[15] = 0xbf;
    out[16] = @truncate(console_handle); // mov $handle, %edi
    out[20] = 0x48;
    out[21] = 0xbe; // movabs $msg, %rsi
    var addr = user_code2 + spin_msg_offset;
    i = 0;
    while (i < 8) : (i += 1) {
        out[22 + i] = @truncate(addr);
        addr >>= 8;
    }
    out[30] = 0xba;
    out[31] = 10; // mov $10, %edx
    out[35] = 0x0f;
    out[36] = 0x05; // syscall write
    out[37] = 0xb8; // mov $0, %eax
    out[42] = 0x31;
    out[43] = 0xff; // xor %edi, %edi
    out[44] = 0x0f;
    out[45] = 0x05; // syscall exit
    out[46] = 0xeb;
    out[47] = 0xfe; // jmp .
    const msg = "USER SPIN\n";
    for (msg, 0..) |c, j| out[spin_msg_offset + j] = c;
    return out;
}

fn buildProgram() [program_len]u8 {
    var out: [program_len]u8 = undefined;
    for (&out) |*b| b.* = 0;
    out[0] = 0xb8;
    out[1] = 1; // mov $1, %eax (write)
    out[5] = 0xbf;
    out[6] = @truncate(console_handle); // mov $handle, %edi
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

// ---- User-mode shell: minimal ELF64 loader and startup ABI ----

const shell_stack_pages: u64 = 2;
const shell_stack_base: u64 = user_base + 0x10_0000;

/// Startup ABI: %rsp points at this struct on entry; other registers are zero.
const StartupInfo = extern struct {
    console: u64,
    reserved: u64,
};

/// Loads a freestanding ELF (ET_EXEC, page-aligned PT_LOAD segments, W^X) into
/// a new address space and enters ring3. Returns the exit status.
pub fn runShell(image: []const u8, console: u64) ?u64 {
    const space = create() orelse return null;
    const entry = loadElf(space, image, shell_stack_base) orelse return null;

    var top_phys: u64 = 0;
    var page: u64 = 0;
    while (page < shell_stack_pages) : (page += 1) {
        top_phys = mapUser(space, shell_stack_base + page * 4096, true, false) orelse return null;
    }
    const startup: *StartupInfo = @ptrFromInt(paging.hhdmOffset() + top_phys + 4096 - @sizeOf(StartupInfo));
    startup.* = .{ .console = console, .reserved = 0 };

    const rsp = shell_stack_base + shell_stack_pages * 4096 - @sizeOf(StartupInfo);
    return syscall.runUser(space, entry, rsp);
}

fn loadElf(space: AddressSpace, image: []const u8, limit: u64) ?u64 {
    if (image.len < 64) return null;
    if (!(image[0] == 0x7f and image[1] == 'E' and image[2] == 'L' and image[3] == 'F')) return null;
    if (image[4] != 2 or image[5] != 1) return null; // 64-bit, little-endian
    if (read16(image, 16) != 2 or read16(image, 18) != 0x3e) return null; // ET_EXEC, x86_64

    const entry = read64(image, 24);
    const phoff = read64(image, 32);
    const ehsize = read16(image, 52);
    const phentsize = read16(image, 54);
    const phnum = read16(image, 56);
    if (ehsize < 64 or phentsize < 56 or phnum == 0 or phnum > 16) return null;
    if (phoff > image.len) return null;
    const ph_end = phoff + @as(u64, phentsize) * phnum;
    if (ph_end > image.len) return null;

    var loaded_end: u64 = 0;
    var entry_ok = false;
    var index: u16 = 0;
    while (index < phnum) : (index += 1) {
        const ph: usize = @intCast(phoff + @as(u64, index) * phentsize);
        if (read32(image, ph) != 1) continue; // PT_LOAD
        const flags = read32(image, ph + 4);
        const offset = read64(image, ph + 8);
        const vaddr = read64(image, ph + 16);
        const filesz = read64(image, ph + 32);
        const memsz = read64(image, ph + 40);

        const writable = (flags & 2) != 0;
        const executable = (flags & 1) != 0;
        if (writable and executable) return null;
        if (filesz > memsz or offset > image.len or filesz > image.len - offset) return null;
        if (vaddr < user_base or (vaddr & 0xfff) != 0 or (offset & 0xfff) != 0) return null;
        if (vaddr >= user_limit or memsz > user_limit - vaddr) return null;
        if (vaddr + memsz > limit) return null;
        if (vaddr < loaded_end) return null;
        if (memsz == 0) continue;

        var page_offset: u64 = 0;
        while (page_offset < memsz) : (page_offset += 4096) {
            const virt = vaddr + page_offset;
            const phys = mapUser(space, virt, writable, executable) orelse return null;
            const dst: [*]u8 = @ptrFromInt(paging.hhdmOffset() + phys);
            if (page_offset < filesz) {
                const chunk: usize = @intCast(@min(filesz - page_offset, 4096));
                @memcpy(dst[0..chunk], image[@intCast(offset + page_offset)..][0..chunk]);
            }
        }
        if (executable and entry >= vaddr and entry < vaddr + memsz) entry_ok = true;
        loaded_end = vaddr + memsz;
    }
    if (!entry_ok) return null;
    return entry;
}

fn read16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn read32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn read64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, read32(bytes, offset)) | (@as(u64, read32(bytes, offset + 4)) << 32);
}

// ---- A2: a second address space and a user thread on another CPU ----

const space_b_test: u64 = user_base + 0x5000;
const space_b_code: u64 = user_base + 0x6000;
const smp_program_len: usize = 62;
const smp_msg_offset: usize = 55;

var smp_space: AddressSpace = undefined;
var smp_ready: bool = false;
var smp_started: u32 = 0; // atomic
var smp_done: u32 = 0; // atomic
var smp_exit_ok: u32 = 0; // atomic

/// Prepares space B: stack, a test page holding 'A', and the polling program.
pub fn prepareUserSmp() bool {
    if (console_handle > 0xff) return false;
    const space = create() orelse return false;
    smp_space = space;
    if (mapUser(space, user_stack, true, false) == null) return false;
    if (mapUser(space, space_b_test, true, false) == null) return false;
    const code_phys = mapUser(space, space_b_code, false, true) orelse return false;

    const hhdm = paging.hhdmOffset();
    const test_pte = paging.pteIn(space.pml4, space_b_test) orelse return false;
    const test_page: [*]u8 = @ptrFromInt(hhdm + paging.physFromPte(test_pte));
    test_page[0] = 'A';

    const code: [*]u8 = @ptrFromInt(hhdm + code_phys);
    const program = buildSmpProgram();
    @memcpy(code[0..program.len], &program);
    smp_ready = true;
    return true;
}

/// Kernel thread body: runs space B's program on its CPU.
pub fn runUserSmpThread() bool {
    if (!smp_ready) return false;
    @atomicStore(u32, &smp_started, 1, .release);
    const status = syscall.runUser(smp_space, space_b_code, user_stack + 0x1000 - 16);
    if (status == 0) {
        if (syscall.exitedWith()) |code| {
            if (code == 0) @atomicStore(u32, &smp_exit_ok, 1, .release);
        }
    }
    @atomicStore(u32, &smp_done, 1, .release);
    return true;
}

/// Boot CPU: remaps the test page to 'B' (with a TLB shootdown) while the
/// worker runs, then waits for it to observe the new contents and exit.
pub fn finishUserSmp() bool {
    const deadline = cpu.rdtsc() + 4_000_000_000;
    while (@atomicLoad(u32, &smp_started, .acquire) == 0) {
        if (cpu.rdtsc() > deadline) return false;
        cpu.pause();
    }
    const settle = cpu.rdtsc() + 50_000_000;
    while (cpu.rdtsc() < settle) cpu.pause();

    const old_pte = paging.pteIn(smp_space.pml4, space_b_test) orelse return false;
    const new_phys = frame.allocFrame() orelse return false;
    const page: [*]u8 = @ptrFromInt(paging.hhdmOffset() + new_phys);
    @memset(page[0..4096], 0);
    page[0] = 'B';
    if (!paging.mapPageIn(smp_space.pml4, space_b_test, new_phys, paging.flags_user | paging.flags_rw | paging.flags_nx)) return false;
    if (!tlb.shootdown()) {
        serial.console.write("A2: shootdown failed\n");
        return false;
    }
    frame.freeFrame(paging.physFromPte(old_pte));

    const wait_deadline = cpu.rdtsc() + 4_000_000_000;
    while (@atomicLoad(u32, &smp_done, .acquire) == 0) {
        if (cpu.rdtsc() > wait_deadline) return false;
        cpu.pause();
    }
    if (@atomicLoad(u32, &smp_exit_ok, .acquire) == 0) return false;
    serial.console.write("USER: space B remapped ok\n");
    return true;
}

fn buildSmpProgram() [smp_program_len]u8 {
    var out: [smp_program_len]u8 = undefined;
    for (&out) |*b| b.* = 0;
    out[0] = 0x48;
    out[1] = 0xbe; // movabs $test, %rsi
    var test_addr = space_b_test;
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        out[2 + i] = @truncate(test_addr);
        test_addr >>= 8;
    }
    out[10] = 0x0f;
    out[11] = 0xb6;
    out[12] = 0x06; // movzbl (%rsi), %eax
    out[13] = 0x3c;
    out[14] = 0x42; // cmp $'B', %al
    out[15] = 0x75;
    out[16] = 0xf9; // jne -7
    out[17] = 0xb8;
    out[18] = 1; // mov $1, %eax
    out[22] = 0xbf;
    out[23] = @truncate(console_handle); // mov $handle, %edi
    out[27] = 0x48;
    out[28] = 0xbe; // movabs $msg, %rsi
    var msg_addr = space_b_code + smp_msg_offset;
    i = 0;
    while (i < 8) : (i += 1) {
        out[29 + i] = @truncate(msg_addr);
        msg_addr >>= 8;
    }
    out[37] = 0xba;
    out[38] = 7; // mov $7, %edx
    out[42] = 0x0f;
    out[43] = 0x05; // syscall write
    out[44] = 0xb8; // mov $0, %eax
    out[49] = 0x31;
    out[50] = 0xff; // xor %edi, %edi
    out[51] = 0x0f;
    out[52] = 0x05; // syscall exit
    out[53] = 0xeb;
    out[54] = 0xfe; // jmp .
    const msg = "B DONE\n";
    for (msg, 0..) |c, j| out[smp_msg_offset + j] = c;
    return out;
}
