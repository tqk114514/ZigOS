//! SYSCALL/SYSRET setup and the first kernel ABI. Entry runs with interrupts
//! masked (FMASK) and no allocation; user pointers only cross via copyFromUser.

const apic = @import("apic.zig");
const serial = @import("serial.zig");
const user = @import("user.zig");

const efer_msr = 0xc0000080;
const star_msr = 0xc0000081;
const lstar_msr = 0xc0000082;
const fmask_msr = 0xc0000084;

pub const number_exit: u64 = 0;
pub const number_write: u64 = 1;
pub const number_yield: u64 = 2;

pub const error_value: u64 = ~@as(u64, 0);

pub const Frame = extern struct {
    r15: u64,
    rbx: u64,
    a3: u64,
    a2: u64,
    a1: u64,
    number: u64,
    rip: u64,
    rflags: u64,
    user_rsp: u64,
};

extern fn syscallEntry() callconv(.c) void;

// M2: one user thread at a time; the owner sets the space before entering.
var space: ?user.AddressSpace = null;
var exit_status: u64 = 0;
var exited: u32 = 0; // atomic

pub fn init() void {
    // STAR: syscall CS/SS from bits 47:32; sysret computes CS = +16, SS = +8
    // from bits 63:48 (our user data 0x18 follows kernel data 0x10).
    apic.wrmsr(efer_msr, apic.rdmsr(efer_msr) | 1); // SCE
    apic.wrmsr(star_msr, (@as(u64, 0x10) << 48) | (@as(u64, 0x08) << 32));
    apic.wrmsr(lstar_msr, @intFromPtr(&syscallEntry));
    apic.wrmsr(fmask_msr, 0x700 | 0x40000); // TF|IF|DF|AC
}

pub fn setAddressSpace(address_space: user.AddressSpace) void {
    space = address_space;
}

pub fn exitedWith() ?u64 {
    if (@atomicLoad(u32, &exited, .acquire) == 0) return null;
    return exit_status;
}

pub fn resetExit() void {
    exit_status = 0;
    @atomicStore(u32, &exited, 0, .release);
}

export fn syscallHandler(frame: *Frame) callconv(.c) u64 {
    switch (frame.number) {
        number_write => return write(frame.a1, frame.a2, frame.a3),
        number_yield => return 0, // preemption already covers it
        number_exit => {
            exit_status = frame.a1;
            @atomicStore(u32, &exited, 1, .release);
            return 0;
        },
        else => return error_value,
    }
}

fn write(handle: u64, ptr: u64, len: u64) u64 {
    if (handle != 1) return error_value; // console handle
    if (len > 4096) return error_value;
    const address_space = space orelse return error_value;

    var buf: [64]u8 = undefined;
    var done: u64 = 0;
    while (done < len) {
        const chunk: usize = @intCast(@min(len - done, 64));
        if (!user.copyFromUser(address_space, buf[0..chunk], ptr + done)) return error_value;
        serial.console.write(buf[0..chunk]);
        done += chunk;
    }
    return 0;
}
