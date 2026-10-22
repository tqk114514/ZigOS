//! Hardware abstraction interfaces. No implementations, no policy.

pub const Console = struct {
    write_fn: *const fn (bytes: []const u8) void,

    pub fn write(self: Console, bytes: []const u8) void {
        self.write_fn(bytes);
    }
};
