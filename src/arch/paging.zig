//! Page-table map/translate over Limine's CR3, with optional 5-level paging.
//! One lock guards all table mutations and walks (order: paging -> frame).

const frame = @import("frame.zig");
const heap = @import("heap.zig");
const spinlock = @import("spinlock.zig");

pub const flags_present: u64 = 1 << 0;
pub const flags_rw: u64 = 1 << 1;
pub const flags_user: u64 = 1 << 2;
pub const flags_uc: u64 = 1 << 4; // PCD: MMIO must not be cached
pub const flags_ps: u64 = 1 << 7; // large-page bit in non-leaf entries
pub const flags_nx: u64 = 1 << 63;

pub const mmio_window: u64 = 0xffff_c000_0000_0000;

const phys_mask: u64 = 0x000F_FFFF_FFFF_F000;

var hhdm: u64 = 0;
var five_level: bool = false;
var lock: spinlock.Lock align(64) = .{};

pub fn init(hhdm_offset: u64) void {
    hhdm = hhdm_offset;
    five_level = (currentCr4() & (1 << 12)) != 0;
}

pub fn isFiveLevel() bool {
    return five_level;
}

pub fn hhdmOffset() u64 {
    return hhdm;
}

var demand_faults: u64 = 0; // atomic

pub fn demandFaults() u64 {
    return @atomicLoad(u64, &demand_faults, .monotonic);
}

pub fn handlePageFault(error_code: u64) bool {
    const fault_addr = readCr2();
    const page = fault_addr & ~@as(u64, 0xfff);
    // Present faults are protection faults and stay fatal in M2.
    if ((error_code & 1) != 0) return false;
    if (!heap.contains(page)) return false;

    const irq = lock.acquire();
    defer lock.release(irq);
    const cr3 = currentCr3() & phys_mask;
    // Another CPU may have mapped the page in the meantime.
    if (translateLocked(cr3, page) != null) return true;
    const phys = frame.allocFrame() orelse return false;
    if (!mapPageLocked(cr3, page, phys, flags_rw | flags_nx)) return false;
    _ = @atomicRmw(u64, &demand_faults, .Add, 1, .monotonic);
    return true;
}

pub fn mapPage(virt: u64, phys: u64, flags: u64) bool {
    return mapPageIn(currentCr3() & phys_mask, virt, phys, flags);
}

pub fn mapPageIn(pml4_phys: u64, virt: u64, phys: u64, flags: u64) bool {
    const irq = lock.acquire();
    defer lock.release(irq);
    return mapPageLocked(pml4_phys, virt, phys, flags);
}

fn mapPageLocked(pml4_phys: u64, virt: u64, phys: u64, flags: u64) bool {
    var table = tablePtr(pml4_phys);
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

/// Maps the 4 KiB page containing `phys` into the MMIO window (uncached, NX)
/// and returns its kernel virtual address. Idempotent.
pub fn mapMmioPage(phys: u64) ?u64 {
    const page = phys & ~@as(u64, 0xfff);
    const virt = mmio_window + page;
    if (translate(virt) == null) {
        if (!mapPage(virt, page, flags_rw | flags_uc | flags_nx)) return null;
    }
    return mmio_window + phys;
}

/// Translates a virtual address mapped by `mapPage`. Huge-page (PS) entries
/// are not interpreted; walking a large-page region yields garbage.
pub fn translate(virt: u64) ?u64 {
    const irq = lock.acquire();
    defer lock.release(irq);
    return translateLocked(currentCr3() & phys_mask, virt);
}

fn translateLocked(pml4_phys: u64, virt: u64) ?u64 {
    var table = tablePtr(pml4_phys);
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

/// Raw leaf PTE for a 4/5-level walk in the given address space.
pub fn pteIn(pml4_phys: u64, virt: u64) ?u64 {
    const irq = lock.acquire();
    defer lock.release(irq);
    var table = tablePtr(pml4_phys);
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
    return e1;
}

pub fn physFromPte(pte: u64) u64 {
    return pte & phys_mask;
}

/// Builds a user address space's PML4: entries 256..512 are shared with the
/// kernel's current PML4, the lower half is empty.
pub fn copyKernelEntries(new_pml4: u64) bool {
    const irq = lock.acquire();
    defer lock.release(irq);
    const src = tablePtr(currentCr3() & phys_mask);
    const dst = tablePtr(new_pml4);
    var i: usize = 0;
    while (i < 256) : (i += 1) dst[i] = 0;
    i = 256;
    while (i < 512) : (i += 1) dst[i] = src[i];
    return true;
}

/// Frees a user space built by mapPageIn(): every lower-half leaf and page
/// table, then the PML4. The space must be inactive on all CPUs; the upper
/// half holds shared kernel tables and is left untouched.
pub fn destroyUserSpace(pml4_phys: u64) void {
    const irq = lock.acquire();
    defer lock.release(irq);

    const pml4 = tablePtr(pml4_phys);
    var pml4_index: usize = 0;
    while (pml4_index < 256) : (pml4_index += 1) {
        const e4 = pml4[pml4_index];
        if ((e4 & flags_present) == 0) continue;
        if ((e4 & flags_ps) != 0) continue; // large pages are never created here
        const p3 = tablePtr(e4 & phys_mask);
        var pdpt_index: usize = 0;
        while (pdpt_index < 512) : (pdpt_index += 1) {
            const e3 = p3[pdpt_index];
            if ((e3 & flags_present) == 0) continue;
            if ((e3 & flags_ps) != 0) continue;
            const p2 = tablePtr(e3 & phys_mask);
            var pd_index: usize = 0;
            while (pd_index < 512) : (pd_index += 1) {
                const e2 = p2[pd_index];
                if ((e2 & flags_present) == 0) continue;
                if ((e2 & flags_ps) != 0) continue;
                const p1 = tablePtr(e2 & phys_mask);
                var pt_index: usize = 0;
                while (pt_index < 512) : (pt_index += 1) {
                    const e1 = p1[pt_index];
                    if ((e1 & flags_present) == 0) continue;
                    frame.freeFrame(e1 & phys_mask);
                }
                frame.freeFrame(e2 & phys_mask);
            }
            frame.freeFrame(e3 & phys_mask);
        }
        frame.freeFrame(e4 & phys_mask);
    }
    frame.freeFrame(pml4_phys);
}

/// Allocates a zeroed frame and maps it RW/NX at `virt` in the kernel space.
pub fn allocKernelPage(virt: u64) bool {
    const phys = frame.allocFrame() orelse return false;
    // SAFETY: the frame is RAM reachable through the HHDM.
    const page: [*]u8 = @ptrFromInt(hhdm + phys);
    @memset(page[0..4096], 0);
    return mapPage(virt, phys, flags_rw | flags_nx);
}

/// Installs a new PML4; returns the previous one. The kernel half must be
/// shared (create() guarantees that).
pub fn activate(pml4_phys: u64) u64 {
    const previous = currentCr3() & phys_mask;
    // SAFETY: writing CR3 at CPL0; the new tables keep the kernel half mapped.
    asm volatile ("movq %[value], %%cr3"
        :
        : [value] "r" (pml4_phys),
        : .{ .memory = true });
    return previous;
}

/// Address that caused the current page fault (CR2).
pub fn faultAddress() u64 {
    return readCr2();
}

pub fn tablePtr(phys: u64) *[512]u64 {
    // SAFETY: HHDM maps all physical RAM; page tables are 4 KiB frames.
    return @ptrFromInt(hhdm + phys);
}

fn ensureTable(entry: *u64) ?*[512]u64 {
    if ((entry.* & flags_present) != 0) {
        // Huge-page (PS) entries are not split yet; the M2 path only walks
        // fresh 4-level tables.
        return tablePtr(entry.* & phys_mask);
    }
    const phys = frame.allocFrame() orelse return null;
    const table = tablePtr(phys);
    @memset(table[0..], 0);
    // U/S on intermediate tables is harmless: user access still requires a
    // user leaf PTE, which kernel mappings never have.
    entry.* = phys | flags_present | flags_rw | flags_user;
    return table;
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
