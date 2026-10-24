//! Read-only initramfs image: a self-contained flat archive.
//!
//! Layout: magic "ZRAM", then entries `u16 name_len, name, u32 data_len,
//! data`; a zero name length terminates the image. Parsing is a zero-copy,
//! zero-allocation scan; malformed input yields null.

const magic = "ZRAM";

pub const FileSpec = struct {
    name: []const u8,
    data: []const u8,
};

/// Returns the file data for `name`, or null when absent or malformed.
pub fn find(image: []const u8, name: []const u8) ?[]const u8 {
    if (image.len < magic.len or !eq(image[0..magic.len], magic)) return null;
    var offset: usize = magic.len;
    while (offset + 2 <= image.len) {
        const name_len = readU16(image, offset);
        offset += 2;
        if (name_len == 0) return null;
        if (offset + name_len + 4 > image.len) return null;
        const entry_name = image[offset .. offset + name_len];
        offset += name_len;
        const data_len = readU32(image, offset);
        offset += 4;
        if (offset + data_len > image.len) return null;
        const data = image[offset .. offset + data_len];
        offset += data_len;
        if (eq(entry_name, name)) return data;
    }
    return null;
}

/// True when the image is well-formed up to its terminator.
pub fn valid(image: []const u8) bool {
    if (image.len < magic.len or !eq(image[0..magic.len], magic)) return false;
    var offset: usize = magic.len;
    while (offset + 2 <= image.len) {
        const name_len = readU16(image, offset);
        offset += 2;
        if (name_len == 0) return true;
        if (offset + name_len + 4 > image.len) return false;
        offset += name_len;
        const data_len = readU32(image, offset);
        offset += 4;
        if (offset + data_len > image.len) return false;
        offset += data_len;
    }
    return false;
}

/// Builds an image from `files` at compile time.
fn imageLen(comptime files: []const FileSpec) usize {
    var total: usize = magic.len;
    inline for (files) |file| {
        total += 2 + file.name.len + 4 + file.data.len;
    }
    return total + 2;
}

pub fn buildImage(comptime files: []const FileSpec) [imageLen(files)]u8 {
    const len = imageLen(files);
    var out: [len]u8 = undefined;
    var offset: usize = 0;
    inline for (magic) |c| {
        out[offset] = c;
        offset += 1;
    }
    inline for (files) |file| {
        out[offset] = @truncate(file.name.len);
        out[offset + 1] = @truncate(file.name.len >> 8);
        offset += 2;
        for (file.name) |c| {
            out[offset] = c;
            offset += 1;
        }
        out[offset] = @truncate(file.data.len);
        out[offset + 1] = @truncate(file.data.len >> 8);
        out[offset + 2] = @truncate(file.data.len >> 16);
        out[offset + 3] = @truncate(file.data.len >> 24);
        offset += 4;
        for (file.data) |c| {
            out[offset] = c;
            offset += 1;
        }
    }
    out[offset] = 0;
    out[offset + 1] = 0;
    return out;
}

const demo_bytes = buildImage(&.{
    .{ .name = "/hello.txt", .data = "hello from initramfs\n" },
    .{ .name = "/motd", .data = "ZigOS M3\n" },
    .{ .name = "/empty", .data = "" },
});

pub const demo: []const u8 = &demo_bytes;

fn eq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn readU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}
