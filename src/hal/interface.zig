//! Hardware abstraction interfaces. No implementations, no policy.

pub const Console = struct {
    write_fn: *const fn (bytes: []const u8) void,

    pub fn write(self: Console, bytes: []const u8) void {
        self.write_fn(bytes);
    }
};

/// A block device exposes synchronous sector reads. Drivers own the backing
/// state; callers only see this value type. `buf` must be exactly one sector.
pub const BlockDevice = struct {
    ctx: *anyopaque,
    read_fn: *const fn (ctx: *anyopaque, lba: u64, buf: []u8) bool,
    sector_size: u32,

    pub fn read(self: BlockDevice, lba: u64, buf: []u8) bool {
        return self.read_fn(self.ctx, lba, buf);
    }
};
