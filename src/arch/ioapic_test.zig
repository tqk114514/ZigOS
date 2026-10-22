const std = @import("std");
const ioapic = @import("ioapic.zig");

test "redirection entry packing" {
    // Vector in bits 0-7; bus-conforming flags stay active-high edge.
    try std.testing.expectEqual(@as(u32, 0x30), ioapic.redirLow(0x30, 0));
    // MPS INTI flags: polarity 11 -> active low (bit 13), trigger 11 -> level (bit 15).
    try std.testing.expectEqual(
        @as(u32, 0x30 | (1 << 13) | (1 << 15)),
        ioapic.redirLow(0x30, 0x000f),
    );
    // Explicit active-high edge.
    try std.testing.expectEqual(@as(u32, 0x30), ioapic.redirLow(0x30, 0x0005));
    try std.testing.expectEqual(@as(u32, 0x80 << 24), ioapic.redirHigh(0x80));
}

test "version register max redirection index" {
    try std.testing.expectEqual(@as(u32, 0x17), ioapic.maxRedirIndex(0x0017_0020));
    try std.testing.expectEqual(@as(u32, 0), ioapic.maxRedirIndex(0));
}
