//! ACPI discovery for interrupt routing: RSDP -> XSDT -> MADT, yielding the
//! IOAPIC base and the ISA interrupt source overrides.
//!
//! Parsing is pure: `load` takes the RSDP address and the HHDM offset, so the
//! boot path passes Limine's values and host tests pass a synthetic buffer.
//! Table-internal addresses are physical (ACPI spec) and are read via HHDM.

const max_isos: usize = 16;

const table_header_size: usize = 36;
const madt_header_size: usize = 44;
const max_table_size: u64 = 1 << 20;

pub const Ioapic = struct {
    id: u8,
    base: u32,
    gsi_base: u32,
};

pub const Iso = struct {
    source: u8, // ISA IRQ number
    gsi: u32,
    flags: u16, // MPS INTI flags: bits 0-1 polarity, bits 2-3 trigger
};

pub const Ecam = struct {
    base: u64,
    start_bus: u8,
    end_bus: u8,
};

// Boot-once state; written by load(), read-only afterwards.
var ioapic_entry: ?Ioapic = null;
var isos: [max_isos]Iso = undefined;
var iso_count: usize = 0;
var ecam_entry: ?Ecam = null;

/// Locates and parses the MADT and, when present, the MCFG. Returns false when
/// the RSDP/XSDT chain is missing or malformed, a wanted table fails its
/// checksum, or neither table was found.
pub fn load(rsdp_addr: u64, hhdm: u64) bool {
    ioapic_entry = null;
    iso_count = 0;
    ecam_entry = null;

    const rsdp_head = bytesAt(rsdp_addr, 24);
    if (!eq(rsdp_head[0..8], "RSD PTR ")) return false;
    if (!checksumOk(rsdp_head[0..20])) return false;
    // Only the ACPI 2.0+ XSDT path is implemented (M1).
    if (rsdp_head[15] < 2) return false;
    const rsdp_len = readU32(rsdp_head, 20);
    if (rsdp_len < table_header_size or rsdp_len > 64) return false;
    const rsdp = bytesAt(rsdp_addr, rsdp_len);
    if (!checksumOk(rsdp)) return false;

    const xsdt_phys = readU64(rsdp, 24);
    if (xsdt_phys == 0) return false;

    const xsdt_head = bytesAt(hhdm + xsdt_phys, 8);
    const xsdt_len = readU32(xsdt_head, 4);
    if (xsdt_len < table_header_size or xsdt_len > max_table_size) return false;
    const xsdt = bytesAt(hhdm + xsdt_phys, xsdt_len);
    if (!eq(xsdt[0..4], "XSDT") or !checksumOk(xsdt)) return false;

    var found_madt = false;
    var offset: usize = table_header_size;
    while (offset + 8 <= xsdt_len) : (offset += 8) {
        const table_phys = readU64(xsdt, offset);
        if (table_phys == 0) continue;
        const head = bytesAt(hhdm + table_phys, 8);
        const len = readU32(head, 4);
        if (eq(head[0..4], "APIC")) {
            if (len < madt_header_size or len > max_table_size) return false;
            const madt = bytesAt(hhdm + table_phys, len);
            if (!checksumOk(madt)) return false;
            if (!parseMadt(madt)) return false;
            found_madt = true;
        } else if (eq(head[0..4], "MCFG")) {
            if (len < table_header_size + 8 + 16 or len > max_table_size) return false;
            const mcfg = bytesAt(hhdm + table_phys, len);
            if (!checksumOk(mcfg)) return false;
            parseMcfg(mcfg);
        }
    }
    return found_madt or ecam_entry != null;
}

/// PCIe ECAM window from the MCFG allocation structure (first entry). The
/// structure follows an 8-byte reserved field, so it starts at offset 44:
/// base(8), segment(2), start_bus(1), end_bus(1), reserved(4). Only segment 0
/// is accepted; config address calculation is segment-relative.
fn parseMcfg(bytes: []const u8) void {
    const entry = table_header_size + 8;
    if (readU16(bytes, entry + 8) != 0) return;
    const start_bus = bytes[entry + 10];
    const end_bus = bytes[entry + 11];
    if (start_bus > end_bus) return;
    ecam_entry = .{
        .base = readU64(bytes, entry),
        .start_bus = start_bus,
        .end_bus = end_bus,
    };
}

pub fn ecam() ?Ecam {
    return ecam_entry;
}

pub fn ioapic() ?Ioapic {
    return ioapic_entry;
}

/// GSI for an ISA IRQ: the MADT override when present, identity otherwise.
pub fn gsiFor(isa_irq: u8) u32 {
    for (isos[0..iso_count]) |iso| {
        if (iso.source == isa_irq) return iso.gsi;
    }
    return isa_irq;
}

/// MPS INTI flags for an ISA IRQ; zero (bus-conforming) when not overridden.
pub fn isoFlags(isa_irq: u8) u16 {
    for (isos[0..iso_count]) |iso| {
        if (iso.source == isa_irq) return iso.flags;
    }
    return 0;
}

fn parseMadt(madt: []const u8) bool {
    var offset: usize = madt_header_size;
    while (offset + 2 <= madt.len) {
        const entry_type = madt[offset];
        const entry_len = madt[offset + 1];
        if (entry_len < 2 or offset + entry_len > madt.len) return false;
        switch (entry_type) {
            1 => { // IOAPIC
                if (entry_len < 12) return false;
                if (ioapic_entry == null) {
                    ioapic_entry = .{
                        .id = madt[offset + 2],
                        .base = readU32(madt, offset + 4),
                        .gsi_base = readU32(madt, offset + 8),
                    };
                }
            },
            2 => { // ISA interrupt source override
                if (entry_len < 10) return false;
                if (iso_count < max_isos) {
                    isos[iso_count] = .{
                        .source = madt[offset + 3],
                        .gsi = readU32(madt, offset + 4),
                        .flags = readU16(madt, offset + 8),
                    };
                    iso_count += 1;
                }
            },
            else => {},
        }
        offset += entry_len;
    }
    return true;
}

fn bytesAt(addr: u64, len: usize) []const u8 {
    // SAFETY: callers pass addresses of firmware tables, which Limine
    // guarantees are mapped through the HHDM at base revision >= 4.
    return @as([*]const u8, @ptrFromInt(addr))[0..len];
}

fn eq(bytes: []const u8, comptime sig: []const u8) bool {
    if (bytes.len < sig.len) return false;
    inline for (sig, 0..) |c, i| {
        if (bytes[i] != c) return false;
    }
    return true;
}

fn checksumOk(bytes: []const u8) bool {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum == 0;
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

fn readU64(bytes: []const u8, offset: usize) u64 {
    return @as(u64, readU32(bytes, offset)) | (@as(u64, readU32(bytes, offset + 4)) << 32);
}
