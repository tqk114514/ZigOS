//! SYSCALL/SYSRET setup and the first kernel ABI. Entry runs with interrupts
//! masked (FMASK) and no allocation; user pointers only cross via copyFromUser.

const apic = @import("apic.zig");
const cpu = @import("cpu.zig");
const paging = @import("paging.zig");
const percpu = @import("percpu.zig");
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
extern fn enterUser(rip: u64, user_rsp: u64, resume_slot: *usize) callconv(.c) u64;
extern fn leaveUserKernel(resume_slot: usize, status: u64) callconv(.c) noreturn;

pub const Dispatch = *const fn (number: u64, a1: u64, a2: u64, a3: u64) u64;

var dispatch_hook: ?Dispatch = null;

pub fn setDispatch(handler: ?Dispatch) void {
    dispatch_hook = handler;
}

var exit_status: u64 = 0;
var exited: u32 = 0; // atomic
var resume_rsp: usize = 0;

pub fn init() void {
    // STAR: syscall CS/SS from bits 47:32; sysret computes CS = +16, SS = +8
    // from bits 63:48 (our user data 0x18 follows kernel data 0x10).
    apic.wrmsr(efer_msr, apic.rdmsr(efer_msr) | 1); // SCE
    apic.wrmsr(star_msr, (@as(u64, 0x10) << 48) | (@as(u64, 0x08) << 32));
    apic.wrmsr(lstar_msr, @intFromPtr(&syscallEntry));
    apic.wrmsr(fmask_msr, 0x700 | 0x40000); // TF|IF|DF|AC
}

pub fn currentAddressSpace() ?user.AddressSpace {
    const pml4 = percpu.current().user_space;
    if (pml4 == 0) return null;
    return .{ .pml4 = pml4 };
}

/// Drops to ring3 at `rip` in `address_space`; returns the exit status once
/// the program exits. The space lives in the per-CPU block so user threads on
/// different CPUs never share it.
pub fn runUser(address_space: user.AddressSpace, rip: u64, user_rsp: u64) u64 {
    const block = percpu.current();
    block.user_space = address_space.pml4;
    const previous = paging.activate(address_space.pml4);
    const status = enterUser(rip, user_rsp, &resume_rsp);
    _ = paging.activate(previous);
    block.user_space = 0;
    // enterUser runs with interrupts off; the kernel thread resumes with them
    // back on (the syscall path left them masked by FMASK).
    cpu.enableInterrupts();
    return status;
}

fn exitUser(status: u64) noreturn {
    exit_status = status;
    @atomicStore(u32, &exited, 1, .release);
    leaveUserKernel(resume_rsp, status);
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
        number_write => {
            const handler = dispatch_hook orelse return error_value;
            return handler(number_write, frame.a1, frame.a2, frame.a3);
        },
        number_yield => return 0, // preemption already covers it
        number_exit => exitUser(frame.a1),
        else => return error_value,
    }
}

/// Copies from a user pointer of the given space (for the dispatch hook).
pub fn copyFromUser(space: user.AddressSpace, dst: []u8, src: u64) bool {
    return user.copyFromUser(space, dst, src);
}
