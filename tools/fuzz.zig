//! Deterministic mutation fuzzer for the initramfs parser (host).
//! The seed is fixed, so any failure is reproducible from the printed run.

const std = @import("std");
const initramfs = @import("../src/fs/initramfs.zig");

const seed: u64 = 0x5eed_2026_1024;
const iterations: usize = 200_000;
const max_image: usize = 4096;

pub fn main(init: std.process.Init) !void {
    _ = init;

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();

    var filler: [max_image]u8 = undefined;
    for (&filler) |*byte| byte.* = random.int(u8);

    var iter: usize = 0;
    while (iter < iterations) : (iter += 1) {
        var buf = filler;
        @memcpy(buf[0..initramfs.demo.len], initramfs.demo);
        var len: usize = initramfs.demo.len;

        const edits = random.intRangeAtMost(u8, 1, 8);
        var edit: usize = 0;
        while (edit < edits) : (edit += 1) {
            switch (random.intRangeAtMost(u8, 0, 4)) {
                0 => {
                    if (len == 0) len = 1;
                    buf[random.uintLessThan(usize, len)] ^= @as(u8, 1) << random.int(u3);
                },
                1 => {
                    if (len == 0) len = 1;
                    buf[random.uintLessThan(usize, len)] = random.int(u8);
                },
                2 => len = random.uintLessThan(usize, max_image + 1),
                3 => {
                    if (len == 0) len = 1;
                    const limit = @min(len, 48);
                    buf[random.uintLessThan(usize, limit)] = random.int(u8);
                },
                else => len = random.uintLessThan(usize, initramfs.demo.len + 1),
            }
        }

        const image = buf[0..len];
        _ = initramfs.valid(image);
        const names = [_][]const u8{ "/hello.txt", "/motd", "/empty", "/a", "/" };
        for (names) |name| {
            const data = initramfs.find(image, name) orelse continue;
            if (!inside(image, data)) return fail(iter);
        }

        var name_buf: [16]u8 = undefined;
        const name_len = random.uintLessThan(usize, name_buf.len + 1);
        for (name_buf[0..name_len]) |*byte| byte.* = random.int(u8);
        if (initramfs.find(image, name_buf[0..name_len])) |data| {
            if (!inside(image, data)) return fail(iter);
        }
    }
    std.debug.print("fuzz: {d} iterations ok (seed 0x{x})\n", .{ iterations, seed });
}

fn inside(image: []const u8, data: []const u8) bool {
    const base = @intFromPtr(image.ptr);
    const start = @intFromPtr(data.ptr);
    if (start < base or start > base + image.len) return false;
    return data.len <= image.len - (start - base);
}

fn fail(iter: usize) error{BadFuzzResult} {
    std.debug.print("fuzz: iteration {d} produced an out-of-image slice\n", .{iter});
    return error.BadFuzzResult;
}
