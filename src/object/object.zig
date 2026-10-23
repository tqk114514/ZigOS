//! Refcounted objects and fixed-capacity handle tables. Handles encode the
//! slot index and its generation, so a reused slot invalidates old handles.

const arch = @import("../arch/interface.zig");
const format = @import("../lib/interface.zig").format;
const encoding = @import("encoding.zig");

pub const capacity: usize = 64;

pub const Rights = struct {
    pub const read: u32 = 1 << 0;
    pub const write: u32 = 1 << 1;
    pub const manage: u32 = 1 << 2;
    pub const all: u32 = read | write | manage;
};

pub const Object = struct {
    kind: u8,
    refs: u32, // atomic
    destroy: ?*const fn (*Object) void,

    pub fn init(kind: u8, destroy: ?*const fn (*Object) void) Object {
        return .{ .kind = kind, .refs = 1, .destroy = destroy };
    }

    pub fn acquire(self: *Object) void {
        _ = @atomicRmw(u32, &self.refs, .Add, 1, .monotonic);
    }

    pub fn release(self: *Object) void {
        if (@atomicRmw(u32, &self.refs, .Sub, 1, .acq_rel) == 1) {
            if (self.destroy) |hook| hook(self);
        }
    }

    pub fn refCount(self: *const Object) u32 {
        return @atomicLoad(u32, &self.refs, .monotonic);
    }
};

const Entry = struct {
    object: *Object = undefined,
    generation: u32 = 0,
    rights: u32 = 0,
    occupied: bool = false,
};

fn emptyEntries(comptime n: usize) [n]Entry {
    var out: [n]Entry = undefined;
    for (&out) |*e| e.* = .{};
    return out;
}

pub const HandleTable = struct {
    lock: arch.Lock align(64) = .{},
    entries: [capacity]Entry = emptyEntries(capacity),

    /// Takes a reference on success; returns null when the table is full.
    pub fn insert(self: *HandleTable, object: *Object, rights: u32) ?u64 {
        const irq = self.lock.acquire();
        var handle: ?u64 = null;
        for (&self.entries, 0..) |*e, i| {
            if (e.occupied) continue;
            e.object = object;
            e.rights = rights;
            e.occupied = true;
            object.acquire();
            handle = encoding.pack(@intCast(i), e.generation);
            break;
        }
        self.lock.release(irq);
        return handle;
    }

    /// Validates slot, generation, and that `rights` is fully granted.
    pub fn lookup(self: *HandleTable, handle: u64, rights: u32) ?*Object {
        const irq = self.lock.acquire();
        var found: ?*Object = null;
        const i = encoding.index(handle);
        if (i < capacity) {
            const e = &self.entries[i];
            if (e.occupied and e.generation == encoding.generation(handle) and
                (e.rights & rights) == rights)
            {
                found = e.object;
            }
        }
        self.lock.release(irq);
        return found;
    }

    /// Releases the reference outside the table lock.
    pub fn remove(self: *HandleTable, handle: u64) bool {
        const irq = self.lock.acquire();
        var removed: ?*Object = null;
        const i = encoding.index(handle);
        if (i < capacity) {
            const e = &self.entries[i];
            if (e.occupied and e.generation == encoding.generation(handle)) {
                e.occupied = false;
                e.generation +%= 1;
                removed = e.object;
            }
        }
        self.lock.release(irq);
        if (removed) |object| {
            object.release();
            return true;
        }
        return false;
    }
};

const kind_test: u8 = 1;
var destroys: u32 = 0;

fn destroyTest(object: *Object) void {
    _ = object;
    destroys += 1;
}

pub fn runSmoke() bool {
    const console = arch.serial_console;

    var object = Object.init(kind_test, &destroyTest);
    var table: HandleTable = .{};

    const h1 = table.insert(&object, Rights.read | Rights.write) orelse return false;
    if (table.lookup(h1, Rights.read) != &object) return false;
    if (table.lookup(h1, Rights.manage) != null) return false;

    const h2 = table.insert(&object, Rights.read) orelse return false;
    if (object.refCount() != 3) return false;
    if (!table.remove(h1)) return false;
    if (table.lookup(h1, Rights.read) != null) return false;
    if (object.refCount() != 2) return false;
    if (!table.remove(h2)) return false;
    if (object.refCount() != 1) return false;

    // Slot reuse must invalidate the old generation.
    const h3 = table.insert(&object, Rights.read) orelse return false;
    if (!table.remove(h3)) return false;
    const h4 = table.insert(&object, Rights.read) orelse return false;
    if (encoding.index(h3) != encoding.index(h4)) return false;
    if (table.lookup(h3, Rights.read) != null) return false;
    if (table.lookup(h4, Rights.read) != &object) return false;
    if (!table.remove(h4)) return false;

    object.release();
    if (destroys != 1) return false;
    console.write("OBJECT: handles ok\n");
    console.write("OBJECT: rights ok\n");

    // Capacity: the 65th insert must fail and refounds must balance.
    var big = Object.init(kind_test, &destroyTest);
    var full: HandleTable = .{};
    var handles: [capacity]u64 = undefined;
    for (&handles) |*slot| {
        slot.* = full.insert(&big, Rights.all) orelse return false;
    }
    if (full.insert(&big, Rights.read) != null) return false;
    if (big.refCount() != capacity + 1) return false;
    for (handles) |h| {
        if (!full.remove(h)) return false;
    }
    if (big.refCount() != 1) return false;
    big.release();
    if (destroys != 2) return false;
    console.write("OBJECT: refcount ok\n");
    console.write("OBJECT: capacity ok\n");
    return true;
}
