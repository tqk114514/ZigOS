//! COM1 serial output, 115200 8N1. All ready-waits are bounded.

const hal = @import("../hal/interface.zig");
const cpu = @import("cpu.zig");
const port = @import("port.zig");
const spinlock = @import("spinlock.zig");

const com1: u16 = 0x3f8;
const max_spin: usize = 1_000_000;
const read_timeout_spins: usize = 20_000_000;

var lock: spinlock.Lock align(64) = .{};
var read_lock: spinlock.Lock align(64) = .{};

pub const console = hal.Console{ .write_fn = write };

pub fn init() void {
    port.outb(com1 + 1, 0x00); // interrupt enable: none
    port.outb(com1 + 3, 0x80); // DLAB on
    port.outb(com1 + 0, 0x01); // divisor low: 1
    port.outb(com1 + 1, 0x00); // divisor high
    port.outb(com1 + 3, 0x03); // 8 data bits, no parity, 1 stop bit
    port.outb(com1 + 2, 0xc7); // FIFO enable and clear
    port.outb(com1 + 4, 0x0b); // RTS/DSR, no interrupts
}

pub fn write(bytes: []const u8) void {
    const irq = lock.acquire();
    defer lock.release(irq);
    for (bytes) |byte| writeByte(byte);
}

fn writeByte(byte: u8) void {
    var spins: usize = 0;
    while ((port.inb(com1 + 5) & 0x20) == 0) : (spins += 1) {
        if (spins >= max_spin) return;
    }
    port.outb(com1, byte);
}

/// Waits a bounded number of polls for at least one byte, then drains up to
/// `buf.len`. Returns 0 when no byte arrived; callers retry.
pub fn read(buf: []u8) usize {
    if (buf.len == 0) return 0;
    const irq = read_lock.acquire();
    defer read_lock.release(irq);

    var done: usize = 0;
    var spins: usize = 0;
    while (done == 0) {
        if ((port.inb(com1 + 5) & 0x01) != 0) {
            buf[0] = port.inb(com1);
            done = 1;
        } else {
            spins += 1;
            if (spins >= read_timeout_spins) return 0;
            cpu.pause();
        }
    }
    while (done < buf.len) : (done += 1) {
        if ((port.inb(com1 + 5) & 0x01) == 0) break;
        buf[done] = port.inb(com1);
    }
    return done;
}
