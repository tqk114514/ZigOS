//! Kernel heap over a demand-mapped virtual range. First-fit free list,
//! no coalescing, bump fallback. The pages are mapped on first touch by the
//! page-fault handler. One lock protects the whole heap; a page fault while
//! holding it only takes the frame lock (order: heap -> frame).

const spinlock = @import("spinlock.zig");

const heap_base: u64 = 0xffff_a000_0000_0000;
const heap_size: u64 = 256 * 1024 * 1024;

const Block = extern struct {
    size: usize,
    next: ?*Block,
};

pub const Stats = struct {
    live_blocks: u64,
    live_bytes: u64, // includes block headers and alignment padding
    capacity_bytes: u64,
};

pub const Heap = struct {
    lock: spinlock.Lock align(64) = .{},
    pos: u64,
    end: u64,
    free_list: ?*Block = null,
    live_blocks: u64 = 0,
    live_bytes: u64 = 0,

    pub fn alloc(self: *Heap, len: usize) ?[]u8 {
        const irq = self.lock.acquire();
        defer self.lock.release(irq);

        const need = align16(len + @sizeOf(Block));
        var prev: ?*Block = null;
        var cur = self.free_list;
        while (cur) |block| {
            if (block.size >= need) {
                if (prev) |p| {
                    p.next = block.next;
                } else {
                    self.free_list = block.next;
                }
                self.live_blocks += 1;
                self.live_bytes += block.size;
                return payload(block, len);
            }
            prev = block;
            cur = block.next;
        }

        const start = self.pos;
        if (start + need > self.end) return null;
        self.pos = start + need;
        const block: *Block = @ptrFromInt(start);
        block.size = need;
        block.next = null;
        self.live_blocks += 1;
        self.live_bytes += need;
        return payload(block, len);
    }

    pub fn free(self: *Heap, bytes: []u8) void {
        const irq = self.lock.acquire();
        defer self.lock.release(irq);

        const start: usize = @intFromPtr(bytes.ptr) - @sizeOf(Block);
        const block: *Block = @ptrFromInt(start);
        self.live_blocks -= 1;
        self.live_bytes -= block.size;
        block.next = self.free_list;
        self.free_list = block;
    }
};

var kernel_heap: Heap = .{
    .pos = heap_base,
    .end = heap_base + heap_size,
};

pub fn stats() Stats {
    const heap = kernel();
    const irq = heap.lock.acquire();
    defer heap.lock.release(irq);
    return .{
        .live_blocks = heap.live_blocks,
        .live_bytes = heap.live_bytes,
        .capacity_bytes = heap_size,
    };
}

pub fn kernel() *Heap {
    return &kernel_heap;
}

pub fn contains(addr: u64) bool {
    return addr >= heap_base and addr < heap_base + heap_size;
}

fn payload(block: *Block, len: usize) []u8 {
    const start: usize = @intFromPtr(block) + @sizeOf(Block);
    // SAFETY: the block came from the heap range and has room for len bytes.
    return @as([*]u8, @ptrFromInt(start))[0..len];
}

fn align16(n: usize) usize {
    return (n + 15) & ~@as(usize, 15);
}
