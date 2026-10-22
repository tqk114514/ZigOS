//! IOAPIC driver over an uncached MMIO mapping: indirect register access and
//! redirection entries for external interrupts. M1 uses the first IOAPIC,
//! fixed delivery, and a physical destination (x2APIC IDs must fit in 8 bits).

const version_reg: u32 = 0x01;
const redir_base: u32 = 0x10;
const mask_bit: u32 = 1 << 16;

const Regs = extern struct {
    select: u32,
    reserved: [3]u32,
    window: u32,
};

pub const Ioapic = struct {
    regs: *volatile Regs,
    gsi_base: u32,
    max_redir: u32,
    version: u32,

    /// Masks every redirection entry; the kernel owns the table afterwards.
    pub fn maskAll(self: Ioapic) void {
        var index: u32 = 0;
        while (index <= self.max_redir) : (index += 1) {
            self.write(redir_base + 2 * index, mask_bit);
        }
    }

    /// Routes `gsi` to `vector` for the given destination (an x2APIC ID),
    /// applying the MADT MPS INTI flags. Unmasks the entry on success.
    pub fn program(self: Ioapic, gsi: u32, vector: u8, flags: u16, dest: u8) bool {
        if (gsi < self.gsi_base) return false;
        const index = gsi - self.gsi_base;
        if (index > self.max_redir) return false;

        const low = redirLow(vector, flags);
        const low_reg = redir_base + 2 * index;
        // Keep the entry masked while the low half is provisional.
        self.write(low_reg, low | mask_bit);
        self.write(low_reg + 1, redirHigh(dest));
        self.write(low_reg, low);
        return true;
    }

    fn read(self: Ioapic, reg: u32) u32 {
        // SAFETY: register I/O through the uncached MMIO mapping; the IOAPIC
        // is only programmed before interrupts are enabled (M1, single CPU).
        self.regs.select = reg;
        return self.regs.window;
    }

    fn write(self: Ioapic, reg: u32, value: u32) void {
        // SAFETY: register I/O through the uncached MMIO mapping; the IOAPIC
        // is only programmed before interrupts are enabled (M1, single CPU).
        self.regs.select = reg;
        self.regs.window = value;
    }
};

/// Wraps an IOAPIC MMIO mapping (see `paging.mapMmioPage`).
pub fn attach(mmio: u64, gsi_base: u32) Ioapic {
    var ioapic = Ioapic{
        // SAFETY: the caller passes a `paging.mapMmioPage` result; the mapping
        // lives for the kernel's lifetime and is uncached (PCD).
        .regs = @ptrFromInt(mmio),
        .gsi_base = gsi_base,
        .max_redir = 0,
        .version = 0,
    };
    ioapic.version = ioapic.read(version_reg);
    ioapic.max_redir = maxRedirIndex(ioapic.version);
    return ioapic;
}

/// Low half of a redirection entry: fixed delivery, physical destination,
/// active-high edge unless the MADT flags say otherwise.
pub fn redirLow(vector: u8, flags: u16) u32 {
    var low: u32 = vector;
    // MPS INTI flags: bits 0-1 polarity (11 = active low), bits 2-3 trigger
    // (11 = level). The bus-conforming value means the ISA default.
    if ((flags & 0x3) == 0x3) low |= 1 << 13;
    if (((flags >> 2) & 0x3) == 0x3) low |= 1 << 15;
    return low;
}

/// High half: the destination field (bits 24-31) carries the x2APIC ID.
pub fn redirHigh(dest: u8) u32 {
    return @as(u32, dest) << 24;
}

/// Number of redirection entries minus one, from the version register.
pub fn maxRedirIndex(version: u32) u32 {
    return (version >> 16) & 0xff;
}
