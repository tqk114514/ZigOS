const std = @import("std");
const format = @import("format.zig");

const Writer = struct {
    buf: *std.ArrayList(u8),

    pub fn write(self: Writer, bytes: []const u8) void {
        self.buf.appendSlice(std.testing.allocator, bytes) catch unreachable;
    }
};

fn expectHex(value: u64, width: usize, expected: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    format.writeHex(Writer{ .buf = &buf }, value, width);
    try std.testing.expectEqualStrings(expected, buf.items);
}

fn expectDec(value: u64, expected: []const u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    format.writeDec(Writer{ .buf = &buf }, value);
    try std.testing.expectEqualStrings(expected, buf.items);
}

test "hex formatting" {
    try expectHex(0, 0, "0");
    try expectHex(0, 1, "0");
    try expectHex(0, 16, "0000000000000000");
    try expectHex(0xdead_beef, 0, "deadbeef");
    try expectHex(0xdead_beef, 16, "00000000deadbeef");
    try expectHex(0xffff_ffff_ffff_ffff, 16, "ffffffffffffffff");
    try expectHex(1, 20, "0000000000000001");
}

test "decimal formatting" {
    try expectDec(0, "0");
    try expectDec(9, "9");
    try expectDec(10, "10");
    try expectDec(255, "255");
    try expectDec(18_446_744_073_709_551_615, "18446744073709551615");
}
