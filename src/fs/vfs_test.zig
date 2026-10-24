const std = @import("std");
const initramfs = @import("initramfs.zig");
const vfs = @import("interface.zig");

test "initramfs finds demo files" {
    try std.testing.expect(initramfs.valid(initramfs.demo));
    try std.testing.expectEqualStrings("hello from initramfs\n", initramfs.find(initramfs.demo, "/hello.txt").?);
    try std.testing.expectEqualStrings("ZigOS M3\n", initramfs.find(initramfs.demo, "/motd").?);
    try std.testing.expectEqual(@as(usize, 0), initramfs.find(initramfs.demo, "/empty").?.len);
    try std.testing.expect(initramfs.find(initramfs.demo, "/missing") == null);
}

test "initramfs rejects malformed images" {
    var bad_magic = initramfs.demo;
    bad_magic = bad_magic[1..];
    try std.testing.expect(!initramfs.valid(bad_magic));
    try std.testing.expect(initramfs.find(bad_magic, "/hello.txt") == null);

    const truncated = initramfs.demo[0 .. initramfs.demo.len - 3];
    try std.testing.expect(!initramfs.valid(truncated));
    // Entries before the damage still resolve; the truncated tail does not.
    try std.testing.expect(initramfs.find(truncated, "/motd") != null);
    try std.testing.expect(initramfs.find(truncated, "/empty") == null);
}

test "vfs read semantics" {
    var file = try vfs.open("/hello.txt");
    try std.testing.expectEqual(@as(usize, 21), vfs.size(&file));

    var first: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 8), vfs.read(&file, &first));
    try std.testing.expectEqualStrings("hello fr", &first);

    var rest: [64]u8 = undefined;
    const n = vfs.read(&file, &rest);
    try std.testing.expectEqual(@as(usize, 13), n);
    try std.testing.expectEqualStrings("om initramfs\n", rest[0..n]);
    try std.testing.expect(vfs.eof(&file));
    try std.testing.expectEqual(@as(usize, 0), vfs.read(&file, &rest));

    const empty = try vfs.open("/empty");
    try std.testing.expectEqual(@as(usize, 0), vfs.read(@constCast(&empty), &rest));
    try std.testing.expectError(error.NotFound, vfs.open("/nope"));
}
