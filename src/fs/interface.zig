//! Read-only flat VFS over the built-in initramfs. Paths are exact keys with
//! a leading '/'; a directory tree arrives with the packaged-image increment.

const initramfs = @import("initramfs.zig");

pub const Error = error{NotFound};

pub const File = struct {
    data: []const u8,
    pos: usize,
};

pub fn open(path: []const u8) Error!File {
    const data = initramfs.find(initramfs.demo, path) orelse return error.NotFound;
    return .{ .data = data, .pos = 0 };
}

/// Copies up to buf.len bytes; returns 0 at end of file.
pub fn read(file: *File, buf: []u8) usize {
    const available = file.data.len - file.pos;
    const n = @min(buf.len, available);
    @memcpy(buf[0..n], file.data[file.pos..][0..n]);
    file.pos += n;
    return n;
}

pub fn size(file: *const File) usize {
    return file.data.len;
}

pub fn eof(file: *const File) bool {
    return file.pos >= file.data.len;
}
