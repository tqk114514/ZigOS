//! Packs a directory into the kernel's ZRAM initramfs image (host tool).
//!
//! Usage: mkinitramfs <source-dir> <output-image>

const std = @import("std");
const image_format = @import("../src/fs/initramfs.zig");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 3) {
        std.debug.print("usage: mkinitramfs <source-dir> <output-image>\n", .{});
        std.process.exit(2);
    }
    const source = args[1];
    const output = args[2];

    var dir = std.Io.Dir.cwd().openDir(init.io, source, .{ .iterate = true }) catch |err| {
        std.debug.print("mkinitramfs: cannot open '{s}': {s}\n", .{ source, @errorName(err) });
        std.process.exit(2);
    };
    defer dir.close(init.io);

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(arena);
    var walker = dir.walk(arena) catch |err| {
        std.debug.print("mkinitramfs: walk '{s}': {s}\n", .{ source, @errorName(err) });
        std.process.exit(2);
    };
    defer walker.deinit();
    while (true) {
        const maybe_entry = try walker.next(init.io);
        const entry = maybe_entry orelse break;
        if (entry.kind != .file) continue;
        const rel = try normalizeSlashes(arena, entry.path);
        try names.append(arena, try std.fmt.allocPrint(arena, "/{s}", .{rel}));
    }
    std.mem.sort([]const u8, names.items, {}, lessThan);

    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(arena);
    try image.appendSlice(arena, "ZRAM");
    for (names.items) |name| {
        const rel = name[1..];
        const data = dir.readFileAlloc(init.io, rel, arena, .limited(1 << 24)) catch |err| {
            std.debug.print("mkinitramfs: read '{s}': {s}\n", .{ rel, @errorName(err) });
            std.process.exit(2);
        };
        try appendEntry(arena, &image, name, data);
    }
    try image.appendSlice(arena, &.{ 0, 0 });

    if (!image_format.valid(image.items)) {
        std.debug.print("mkinitramfs: packed image is invalid\n", .{});
        std.process.exit(1);
    }

    const out_dir_path = std.fs.path.dirname(output) orelse ".";
    if (out_dir_path.len != 0) {
        try std.Io.Dir.cwd().createDirPath(init.io, out_dir_path);
    }
    var file = try std.Io.Dir.cwd().createFile(init.io, output, .{});
    defer file.close(init.io);
    try file.writeStreamingAll(init.io, image.items);
    std.debug.print("mkinitramfs: {d} entries, {d} bytes\n", .{ names.items.len, image.items.len });
}

fn appendEntry(
    allocator: std.mem.Allocator,
    image: *std.ArrayList(u8),
    name: []const u8,
    data: []const u8,
) !void {
    if (name.len == 0 or name.len > 0xffff or data.len > 0xffff_ffff) return error.EntryTooLarge;
    try image.append(allocator, @truncate(name.len));
    try image.append(allocator, @truncate(name.len >> 8));
    try image.appendSlice(allocator, name);
    try image.append(allocator, @truncate(data.len));
    try image.append(allocator, @truncate(data.len >> 8));
    try image.append(allocator, @truncate(data.len >> 16));
    try image.append(allocator, @truncate(data.len >> 24));
    try image.appendSlice(allocator, data);
}

fn normalizeSlashes(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test "packed image round-trips through the kernel parser" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var image: std.ArrayList(u8) = .empty;
    defer image.deinit(arena);
    try image.appendSlice(arena, "ZRAM");
    try appendEntry(arena, &image, "/b.txt", "second");
    try appendEntry(arena, &image, "/a.txt", "first");
    try image.appendSlice(arena, &.{ 0, 0 });

    try std.testing.expect(image_format.valid(image.items));
    try std.testing.expectEqualStrings("first", image_format.find(image.items, "/a.txt").?);
    try std.testing.expectEqualStrings("second", image_format.find(image.items, "/b.txt").?);
    try std.testing.expect(image_format.find(image.items, "/missing") == null);
}
