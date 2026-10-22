//! Physical frame allocator: a bitmap over usable Limine memmap ranges.
//! Initialized once at boot; the bitmap and its lock are the system-wide
//! physical allocator. Counts take the lock, so callers must not hold it.

const limine = @import("limine.zig");
const spinlock = @import("spinlock.zig");

const frame_size: u64 = 4096;
const max_frames: usize = 1 << 20; // 4 GiB of 4 KiB frames
const bitmap_bytes: usize = max_frames / 8;

var lock: spinlock.Lock align(64) = .{};
var bitmap: [bitmap_bytes]u8 = undefined;
var total_frames: u64 = 0;
var free_frames: u64 = 0;
var hint: usize = 0;

pub fn init(memmap: *const limine.MemmapResponse) void {
    const irq = lock.acquire();
    defer lock.release(irq);

    @memset(bitmap[0..], 0xff);
    total_frames = 0;
    free_frames = 0;
    hint = 0;

    const entries = memmap.entries orelse return;
    var i: usize = 0;
    while (i < memmap.entry_count) : (i += 1) {
        const entry = entries[i];
        if (entry.type != 0) continue; // LIMINE_MEMMAP_USABLE
        markFree(entry.base, entry.length);
    }
    // Keep the low 1 MiB (BIOS/legacy structures) out of the allocator.
    markUsed(0, 1 << 20);
}

pub fn allocFrame() ?u64 {
    const irq = lock.acquire();
    defer lock.release(irq);

    if (free_frames == 0) return null;
    var i = hint;
    while (i < max_frames) : (i += 1) {
        if (tryTake(i)) return frameAddress(i);
    }
    i = 0;
    while (i < hint) : (i += 1) {
        if (tryTake(i)) return frameAddress(i);
    }
    return null;
}

pub fn freeFrame(phys: u64) void {
    const irq = lock.acquire();
    defer lock.release(irq);

    const index: usize = @intCast(phys / frame_size);
    if (index >= max_frames) return;
    const mask = @as(u8, 1) << @intCast(index % 8);
    if ((bitmap[index / 8] & mask) == 0) return;
    bitmap[index / 8] &= ~mask;
    free_frames += 1;
    if (index < hint) hint = index;
}

pub fn freeCount() u64 {
    const irq = lock.acquire();
    defer lock.release(irq);
    return free_frames;
}

pub fn totalCount() u64 {
    const irq = lock.acquire();
    defer lock.release(irq);
    return total_frames;
}

fn frameAddress(index: usize) u64 {
    return @as(u64, index) * frame_size;
}

fn tryTake(index: usize) bool {
    const mask = @as(u8, 1) << @intCast(index % 8);
    if ((bitmap[index / 8] & mask) != 0) return false;
    bitmap[index / 8] |= mask;
    free_frames -= 1;
    hint = index + 1;
    return true;
}

fn markFree(base: u64, length: u64) void {
    var start: usize = @intCast((base + frame_size - 1) / frame_size);
    const end: usize = @intCast(@min((base + length) / frame_size, max_frames));
    while (start < end) : (start += 1) {
        const mask = @as(u8, 1) << @intCast(start % 8);
        if ((bitmap[start / 8] & mask) != 0) {
            bitmap[start / 8] &= ~mask;
            free_frames += 1;
            total_frames += 1;
        }
    }
}

fn markUsed(base: u64, length: u64) void {
    const start: usize = @intCast(base / frame_size);
    const end: usize = @intCast(@min((base + length) / frame_size, max_frames));
    var i = start;
    while (i < end) : (i += 1) {
        const mask = @as(u8, 1) << @intCast(i % 8);
        if ((bitmap[i / 8] & mask) == 0) {
            bitmap[i / 8] |= mask;
            free_frames -= 1;
        }
    }
}
