//! User processes: an optional address space plus a private handle table.
//! The current process is per-CPU; user code always runs with one attached.
//! Process slots and open files are fixed pools.

const arch = @import("../arch/interface.zig");
const object = @import("../object/interface.zig");
const panic = @import("panic.zig");

pub const kind_console: u8 = 2;
pub const kind_file: u8 = 3;

const max_processes: usize = 4;

pub const Process = struct {
    handles: object.HandleTable = .{},
    space: ?arch.UserSpace = null,
    console: u64 = 0,
    used: bool = false,
};

fn emptyPool() [max_processes]Process {
    var out: [max_processes]Process = undefined;
    for (&out) |*proc| proc.* = .{};
    return out;
}

fn emptyCurrent() [arch.cpu_limit]?*Process {
    var out: [arch.cpu_limit]?*Process = undefined;
    for (&out) |*slot| slot.* = null;
    return out;
}

var pool: [max_processes]Process = emptyPool();
var pool_lock: arch.Lock align(64) = .{};
var console: object.Object = undefined;
// Per-CPU: each CPU writes only its own slot.
var current: [arch.cpu_limit]?*Process = emptyCurrent();

pub fn init() void {
    console = object.Object.init(kind_console, null);

    // Boundary check: a removed handle must stop resolving.
    var probe: object.HandleTable = .{};
    const handle = probe.insert(&console, object.Rights.read) orelse
        panic.call("process handle insert failed", null);
    const alive = probe.lookup(handle, object.Rights.read) != null;
    _ = probe.remove(handle);
    const dead = probe.lookup(handle, object.Rights.read) == null;
    if (!alive or !dead) panic.call("handle table self-check failed", null);
}

/// Claims a process slot and gives it a console handle. The caller owns
/// `space` and must not use it elsewhere afterwards.
pub fn create(space: ?arch.UserSpace) ?*Process {
    const irq = pool_lock.acquire();
    var free: ?*Process = null;
    for (&pool) |*proc| {
        if (proc.used) continue;
        proc.used = true;
        free = proc;
        break;
    }
    pool_lock.release(irq);
    const proc = free orelse return null;

    proc.handles = .{};
    proc.space = space;
    const handle = proc.handles.insert(&console, object.Rights.read | object.Rights.write) orelse {
        proc.used = false;
        return null;
    };
    proc.console = handle;
    return proc;
}

/// Drains the handle table (releasing file slots), frees the address space,
/// and returns the pool slot. The process must not be current on any CPU.
pub fn destroy(proc: *Process) void {
    proc.handles.drain();
    if (proc.space) |space| arch.destroyUserSpace(space);
    const irq = pool_lock.acquire();
    proc.space = null;
    proc.used = false;
    pool_lock.release(irq);
}

pub fn enter(proc: *Process) void {
    current[arch.cpuIndex()] = proc;
}

pub fn leave() void {
    current[arch.cpuIndex()] = null;
}

/// The calling CPU's process table, if user code is running.
pub fn table() ?*object.HandleTable {
    const proc = current[arch.cpuIndex()] orelse return null;
    return &proc.handles;
}

/// Kernel-side fixtures run under a space-less process so their syscalls have
/// a table; the baked console handle is refreshed for hand-written programs.
pub fn beginTest() ?*Process {
    const proc = create(null) orelse return null;
    enter(proc);
    arch.setConsoleHandle(proc.console);
    return proc;
}

pub fn endTest(proc: *Process) void {
    leave();
    destroy(proc);
}

/// Loads and runs the shell inside a fresh process; the space is reclaimed
/// with the process on every exit path.
pub fn runShell(image: []const u8) ?u64 {
    const space = arch.createUserSpace() orelse return null;
    const proc = create(space) orelse {
        arch.destroyUserSpace(space);
        return null;
    };
    enter(proc);
    const status = arch.runShellIn(space, image, proc.console);
    leave();
    destroy(proc);
    return status;
}

/// Two processes must not resolve each other's handles.
pub fn runSelfCheck() bool {
    const a = create(null) orelse return false;
    const b = create(null) orelse {
        destroy(a);
        return false;
    };

    var marker = object.Object.init(7, null);
    const handle = a.handles.insert(&marker, object.Rights.read) orelse {
        destroy(b);
        destroy(a);
        return false;
    };
    const isolated = b.handles.lookup(handle, object.Rights.read) == null;
    marker.release(); // the table holds the only reference

    destroy(b);
    destroy(a);
    return isolated;
}
