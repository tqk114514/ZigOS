//! Kernel syscall dispatch. Handles resolve through the object layer; the
//! console table is kernel-wide for now and per-process tables arrive with the
//! process work.

const arch = @import("../arch/interface.zig");
const object = @import("../object/interface.zig");
const panic = @import("panic.zig");

const kind_console: u8 = 2;
const error_value: u64 = ~@as(u64, 0);

const number_write: u64 = 1;

var console: object.Object = undefined;
var table: object.HandleTable = .{};
var console_handle: u64 = error_value;

pub fn init() void {
    console = object.Object.init(kind_console, null);
    const handle = table.insert(&console, object.Rights.write) orelse
        panic.call("console handle insert failed", null);
    console_handle = handle;
    arch.setConsoleHandle(handle);
    arch.setSyscallDispatch(&dispatch);

    // Boundary check: a removed handle must stop resolving.
    const probe = table.insert(&console, object.Rights.read) orelse
        panic.call("probe handle insert failed", null);
    const alive = table.lookup(probe, object.Rights.read) != null;
    _ = table.remove(probe);
    const dead = table.lookup(probe, object.Rights.read) == null;
    if (!alive or !dead) panic.call("handle table self-check failed", null);
}

pub fn currentHandle() u64 {
    return console_handle;
}

fn dispatch(number: u64, a1: u64, a2: u64, a3: u64) u64 {
    if (number != number_write) return error_value;
    return write(a1, a2, a3);
}

fn write(handle: u64, ptr: u64, len: u64) u64 {
    if (len > 4096) return error_value;
    const target = table.lookup(handle, object.Rights.write) orelse return error_value;
    if (target.kind != kind_console) return error_value;
    const space = arch.currentUserSpace() orelse return error_value;

    var buf: [64]u8 = undefined;
    var done: u64 = 0;
    while (done < len) {
        const chunk: usize = @intCast(@min(len - done, 64));
        if (!arch.copyFromUserSpace(space, buf[0..chunk], ptr + done)) return error_value;
        arch.serial_console.write(buf[0..chunk]);
        done += chunk;
    }
    return 0;
}
