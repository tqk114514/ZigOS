//! Kernel syscall dispatch. Handles resolve through the calling process's
//! table; file state comes from a kernel-wide bounded slot pool.

const arch = @import("../arch/interface.zig");
const fs = @import("../fs/interface.zig");
const object = @import("../object/interface.zig");
const process = @import("process.zig");

const error_value: u64 = ~@as(u64, 0);
const max_path: usize = 64;
const max_files: usize = 8;

const FileSlot = struct {
    object: object.Object = undefined,
    file: fs.File = undefined,
    used: bool = false,
};

fn emptySlots() [max_files]FileSlot {
    var out: [max_files]FileSlot = undefined;
    for (&out) |*slot| slot.* = .{};
    return out;
}

var file_slots: [max_files]FileSlot = emptySlots();
var file_lock: arch.Lock align(64) = .{};

pub fn init() void {
    arch.setSyscallDispatch(&dispatch);
}

fn dispatch(number: u64, a1: u64, a2: u64, a3: u64) u64 {
    return switch (number) {
        arch.syscall_write => write(a1, a2, a3),
        arch.syscall_open => open(a1, a2),
        arch.syscall_read => read(a1, a2, a3),
        arch.syscall_close => close(a1),
        else => error_value,
    };
}

fn write(handle: u64, ptr: u64, len: u64) u64 {
    if (len > 4096) return error_value;
    const table = process.table() orelse return error_value;
    const target = table.lookup(handle, object.Rights.write) orelse return error_value;
    if (target.kind != process.kind_console) return error_value;
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

fn open(path_ptr: u64, path_len: u64) u64 {
    if (path_len == 0 or path_len > max_path) return error_value;
    const space = arch.currentUserSpace() orelse return error_value;
    const table = process.table() orelse return error_value;
    var path: [max_path]u8 = undefined;
    const len: usize = @intCast(path_len);
    if (!arch.copyFromUserSpace(space, path[0..len], path_ptr)) return error_value;
    const file = fs.open(path[0..len]) catch return error_value;

    const irq = file_lock.acquire();
    var free: ?*FileSlot = null;
    for (&file_slots) |*slot| {
        if (slot.used) continue;
        slot.used = true;
        slot.file = file;
        slot.object = object.Object.init(process.kind_file, &destroyFile);
        free = slot;
        break;
    }
    file_lock.release(irq);
    const slot = free orelse return error_value;

    const handle = table.insert(&slot.object, object.Rights.read | object.Rights.manage) orelse {
        slot.object.release(); // destroy marks the slot free
        return error_value;
    };
    slot.object.release(); // the table now owns the reference
    return handle;
}

fn read(handle: u64, ptr: u64, len: u64) u64 {
    if (len == 0 or len > 4096) return error_value;
    const table = process.table() orelse return error_value;
    const target = table.lookup(handle, object.Rights.read) orelse return error_value;
    const space = arch.currentUserSpace() orelse return error_value;
    if (target.kind == process.kind_console) return readConsole(space, ptr, len);
    if (target.kind != process.kind_file) return error_value;

    const slot: *FileSlot = @fieldParentPtr("object", target);
    target.acquire();
    defer target.release();

    var buf: [64]u8 = undefined;
    const want: usize = @intCast(@min(len, 64));
    const irq = file_lock.acquire();
    const got = fs.read(&slot.file, buf[0..want]);
    file_lock.release(irq);
    if (got == 0) return 0;
    if (!arch.copyToUserSpace(space, ptr, buf[0..got])) return error_value;
    return got;
}

fn readConsole(space: arch.UserSpace, ptr: u64, len: u64) u64 {
    var buf: [64]u8 = undefined;
    const want: usize = @intCast(@min(len, 64));
    const got = arch.readSerial(buf[0..want]);
    if (got == 0) return 0;
    if (!arch.copyToUserSpace(space, ptr, buf[0..got])) return error_value;
    return got;
}

fn close(handle: u64) u64 {
    const table = process.table() orelse return error_value;
    if (table.lookup(handle, object.Rights.manage) == null) return error_value;
    if (!table.remove(handle)) return error_value;
    return 0;
}

fn destroyFile(target: *object.Object) void {
    const slot: *FileSlot = @fieldParentPtr("object", target);
    const irq = file_lock.acquire();
    slot.used = false;
    file_lock.release(irq);
}
