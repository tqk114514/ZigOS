//! Page-table map/translate over Limine's CR3, with optional 5-level paging.

const frame = @import("frame.zig");
const heap = @import("heap.zig");

pub const flags_present: u64 = 1 << 0;
pub const flags_rw: u64 = 1 << 1;
pub const flags_nx: u64 = 1 << 63;

const phys_mask: u64 = 0x000F_FFFF_FFFF_F000;

var hhdm: u64 = 0;
var five_level: bool = false;

pub fn init(hhdm_offset: u64) void {
    hhdm = hhdm_offset;
    five_level = (currentCr4() & (1 << 12)) != 0;
}

pub fn isFiveLevel() bool {
    return five_level;
}

var demand_faults: u64 = 0;

pub fn demandFaults() u64 {
    return demand_faults;
}

pub fn handlePageFault(error_code: u64) bool {
    const fault_addr = readCr2();
    const page = fault_addr & ~@as(u64, 0xfff);
    // Present faults are protection faults and stay fatal in M1.
    if ((error_code & 1) != 0) return false;
    if (!heap.contains(page)) return false;
    const phys = frame.allocFrame() orelse return false;
    if (!mapPage(page, phys, flags_rw | flags_nx)) return false;
    demand_faults += 1;
    return true;
}

pub fn mapPage(virt: u64, phys: u64, flags: u64) bool {
    var table = tablePtr(currentCr3() & phys_mask);
    if (five_level) {
        table = ensureTable(&table[(virt >> 48) & 0x1ff]) orelse return false;
    }
    const p3 = ensureTable(&table[(virt >> 39) & 0x1ff]) orelse return false;
    const p2 = ensureTable(&p3[(virt >> 30) & 0x1ff]) orelse return false;
    const p1 = ensureTable(&p2[(virt >> 21) & 0x1ff]) orelse return false;
    p1[(virt >> 12) & 0x1ff] = (phys & phys_mask) | flags | flags_present;
    // SAFETY: flush the translation for the new mapping.
    asm volatile ("invlpg (%[addr])"
        :
        : [addr] "r" (virt),
        : .{ .memory = true });
    return true;
}

pub fn translate(virt: u64) ?u64 {
    var table = tablePtr(currentCr3() & phys_mask);
    if (five_level) {
        const e5 = table[(virt >> 48) & 0x1ff];
        if ((e5 & flags_present) == 0) return null;
        table = tablePtr(e5 & phys_mask);
    }
    const e4 = table[(virt >> 39) & 0x1ff];
    if ((e4 & flags_present) == 0) return null;
    const p3 = tablePtr(e4 & phys_mask);
    const e3 = p3[(virt >> 30) & 0x1ff];
    if ((e3 & flags_present) == 0) return null;
    const p2 = tablePtr(e3 & phys_mask);
    const e2 = p2[(virt >> 21) & 0x1ff];
    if ((e2 & flags_present) == 0) return null;
    const p1 = tablePtr(e2 & phys_mask);
    const e1 = p1[(virt >> 12) & 0x1ff];
    if ((e1 & flags_present) == 0) return null;
    return (e1 & phys_mask) | (virt & 0xfff);
}

fn ensureTable(entry: *u64) ?*[512]u64 {
    if ((entry.* & flags_present) != 0) {
        // Huge-page (PS) entries are not split yet; the M1 smoke path only walks
        // fresh 4-level tables.
        return tablePtr(entry.* & phys_mask);
    }
    const phys = frame.allocFrame() orelse return null;
    const table = tablePtr(phys);
    @memset(table[0..], 0);
    entry.* = phys | flags_present | flags_rw;
    return table;
}

fn tablePtr(phys: u64) *[512]u64 {
    // SAFETY: HHDM maps all physical RAM; page tables are 4 KiB frames.
    return @ptrFromInt(hhdm + phys);
}

fn currentCr3() u64 {
    // SAFETY: reading CR3 at CPL0.
    return asm volatile ("mov %%cr3, %[out]"
        : [out] "=r" (-> u64),
    );
}

fn currentCr4() u64 {
    // SAFETY: reading CR4 at CPL0.
    return asm volatile ("mov %%cr4, %[out]"
        : [out] "=r" (-> u64),
    );
}

fn readCr2() u64 {
    // SAFETY: reading CR2 at CPL0.
    return asm volatile ("mov %%cr2, %[out]"
        : [out] "=r" (-> u64),
    );
}
