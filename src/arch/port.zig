//! x86_64 port I/O primitives. Callers must know the port is valid.

pub fn outb(port: u16, value: u8) void {
    // SAFETY: privileged x86 port I/O with a caller-provided port.
    asm volatile ("outb %[value], %[port]"
        :
        : [value] "{al}" (value),
          [port] "{dx}" (port),
        : .{ .memory = true });
}

pub fn inb(port: u16) u8 {
    // SAFETY: privileged x86 port I/O with a caller-provided port.
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "{dx}" (port),
        : .{ .memory = true });
}
