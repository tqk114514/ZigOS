const std = @import("std");
const acpi = @import("acpi.zig");

const rsdp_off = 0x100;
const xsdt_off = 0x180;
const madt_off = 0x200;
const mcfg_off = 0x300;
const mcfg_len = 36 + 8 + 16;
const madt_len = 44 + 12 + 10;

/// Synthetic ACPI chain in one buffer: `hhdm` is the buffer base, so
/// "physical" table addresses are offsets into it.
const Fixture = struct {
    buf: [0x400]u8 align(16) = undefined,

    fn build(self: *Fixture) void {
        @memset(&self.buf, 0);

        // RSDP 2.0: signature, revision, length, XSDT pointer.
        self.put(rsdp_off, "RSD PTR ");
        self.buf[rsdp_off + 15] = 2;
        self.setU32(rsdp_off + 20, 36);
        self.setU64(rsdp_off + 24, xsdt_off);
        self.fixChecksum(rsdp_off, 20, 8);
        self.fixChecksum(rsdp_off, 36, 32);

        // XSDT with MADT and MCFG entries.
        self.put(xsdt_off, "XSDT");
        self.setU32(xsdt_off + 4, 36 + 16);
        self.setU64(xsdt_off + 36, madt_off);
        self.setU64(xsdt_off + 44, mcfg_off);
        self.fixChecksum(xsdt_off, 36 + 16, 9);

        // MADT: IOAPIC on GSI base 0, plus the IRQ 0 -> GSI 2 override.
        self.put(madt_off, "APIC");
        self.setU32(madt_off + 4, madt_len);
        self.buf[madt_off + 44] = 1; // IOAPIC entry
        self.buf[madt_off + 45] = 12;
        self.buf[madt_off + 46] = 0; // id
        self.setU32(madt_off + 48, 0xfec00000);
        self.setU32(madt_off + 52, 0); // gsi base
        self.buf[madt_off + 56] = 2; // ISA interrupt source override
        self.buf[madt_off + 57] = 10;
        self.buf[madt_off + 59] = 0; // source: IRQ 0
        self.setU32(madt_off + 60, 2); // gsi 2
        self.fixChecksum(madt_off, madt_len, 9);

        // MCFG: ECAM base 0xb0000000, buses 0..255.
        self.put(mcfg_off, "MCFG");
        self.setU32(mcfg_off + 4, mcfg_len);
        self.setU64(mcfg_off + 44, 0xb000_0000);
        // Segment 0, start bus 0, end bus 255 at offsets 52..55.
        self.buf[mcfg_off + 55] = 255;
        self.fixChecksum(mcfg_off, mcfg_len, 9);
    }

    fn dropMcfg(self: *Fixture) void {
        self.setU32(xsdt_off + 4, 36 + 8);
        self.setU64(xsdt_off + 36, madt_off);
        self.fixChecksum(xsdt_off, 36 + 8, 9);
    }

    fn base(self: *const Fixture) u64 {
        return @intFromPtr(&self.buf);
    }

    fn put(self: *Fixture, offset: usize, comptime sig: []const u8) void {
        @memcpy(self.buf[offset..][0..sig.len], sig);
    }

    fn setU32(self: *Fixture, offset: usize, value: u32) void {
        self.buf[offset] = @truncate(value);
        self.buf[offset + 1] = @truncate(value >> 8);
        self.buf[offset + 2] = @truncate(value >> 16);
        self.buf[offset + 3] = @truncate(value >> 24);
    }

    fn setU64(self: *Fixture, offset: usize, value: u64) void {
        self.setU32(offset, @truncate(value));
        self.setU32(offset + 4, @truncate(value >> 32));
    }

    fn fixChecksum(self: *Fixture, offset: usize, len: usize, field: usize) void {
        const bytes = self.buf[offset..][0..len];
        bytes[field] = 0;
        var sum: u8 = 0;
        for (bytes) |b| sum +%= b;
        bytes[field] = 0 -% sum;
    }
};

test "load parses the MADT chain" {
    var f: Fixture = .{};
    f.build();
    try std.testing.expect(acpi.load(f.base() + rsdp_off, f.base()));

    const ioapic = acpi.ioapic() orelse return error.MissingIoapic;
    try std.testing.expectEqual(@as(u8, 0), ioapic.id);
    try std.testing.expectEqual(@as(u32, 0xfec00000), ioapic.base);
    try std.testing.expectEqual(@as(u32, 0), ioapic.gsi_base);
    try std.testing.expectEqual(@as(u32, 2), acpi.gsiFor(0));
    try std.testing.expectEqual(@as(u32, 8), acpi.gsiFor(8));
    try std.testing.expectEqual(@as(u16, 0), acpi.isoFlags(0));
    try std.testing.expectEqual(@as(u16, 0), acpi.isoFlags(8));

    const ecam = acpi.ecam() orelse return error.MissingEcam;
    try std.testing.expectEqual(@as(u64, 0xb000_0000), ecam.base);
    try std.testing.expectEqual(@as(u8, 0), ecam.start_bus);
    try std.testing.expectEqual(@as(u8, 255), ecam.end_bus);
}

test "load tolerates a missing MCFG" {
    var f: Fixture = .{};
    f.build();
    f.dropMcfg();
    try std.testing.expect(acpi.load(f.base() + rsdp_off, f.base()));
    try std.testing.expect(acpi.ecam() == null);
}

test "load ignores MCFG entries outside segment 0" {
    var f: Fixture = .{};
    f.build();
    f.buf[mcfg_off + 52] = 1; // segment group
    f.fixChecksum(mcfg_off, mcfg_len, 9);
    try std.testing.expect(acpi.load(f.base() + rsdp_off, f.base()));
    try std.testing.expect(acpi.ecam() == null);
}

test "load rejects a broken signature" {
    var f: Fixture = .{};
    f.build();
    f.buf[rsdp_off] = 'X';
    try std.testing.expect(!acpi.load(f.base() + rsdp_off, f.base()));
}

test "load rejects tables with bad checksums" {
    var f: Fixture = .{};
    f.build();
    f.buf[madt_off + 46] ^= 0xff; // flip an IOAPIC entry byte
    try std.testing.expect(!acpi.load(f.base() + rsdp_off, f.base()));
}

test "load rejects ACPI 1.0 RSDPs" {
    var f: Fixture = .{};
    f.build();
    f.buf[rsdp_off + 15] = 1;
    f.fixChecksum(rsdp_off, 20, 8);
    try std.testing.expect(!acpi.load(f.base() + rsdp_off, f.base()));
}

test "load rejects malformed MADT entries" {
    var f: Fixture = .{};
    f.build();
    f.buf[madt_off + 45] = 1; // entry length below the two-byte minimum
    f.fixChecksum(madt_off, madt_len, 9);
    try std.testing.expect(!acpi.load(f.base() + rsdp_off, f.base()));
}
