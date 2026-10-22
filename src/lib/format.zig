//! Allocation-free integer formatting for kernel output.
//!
//! The writer must expose `write(bytes: []const u8) void`.

pub fn writeHex(writer: anytype, value: u64, width: usize) void {
    const digits = "0123456789abcdef";
    var buf: [16]u8 = undefined;
    var i: usize = buf.len;
    var v = value;

    while (true) {
        i -= 1;
        buf[i] = digits[@intCast(v & 0xf)];
        v >>= 4;
        if (v == 0) break;
    }

    const min_digits = @min(width, buf.len);
    while (buf.len - i < min_digits) {
        i -= 1;
        buf[i] = '0';
    }
    writer.write(buf[i..]);
}

pub fn writeDec(writer: anytype, value: u64) void {
    const digits = "0123456789";
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var v = value;

    while (true) {
        i -= 1;
        buf[i] = digits[@intCast(v % 10)];
        v /= 10;
        if (v == 0) break;
    }
    writer.write(buf[i..]);
}
