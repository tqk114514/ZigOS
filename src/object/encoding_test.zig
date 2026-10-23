const std = @import("std");
const encoding = @import("encoding.zig");

test "handle round trip" {
    const cases = [_]struct { index: u32, generation: u32 }{
        .{ .index = 0, .generation = 0 },
        .{ .index = 63, .generation = 1 },
        .{ .index = 0x00ff_ffff, .generation = 0xffff_ffff },
    };
    for (cases) |c| {
        const handle = encoding.pack(c.index, c.generation);
        try std.testing.expectEqual(c.index, encoding.index(handle));
        try std.testing.expectEqual(c.generation, encoding.generation(handle));
    }
}

test "neighbouring generations are distinct" {
    const a = encoding.pack(7, 0);
    const b = encoding.pack(7, 1);
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(u32, 7), encoding.index(b));
}
