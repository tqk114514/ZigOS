//! virtio-blk discovery: PCIe ECAM enumeration, modern virtio PCI
//! capabilities, and BAR mapping. Queue setup and sector reads arrive with
//! the next increment.

const arch = @import("../arch/interface.zig");
const format = @import("../lib/interface.zig").format;

const virtio_vendor: u16 = 0x1af4;
const device_legacy: u16 = 0x1001; // transitional; modern caps required
const device_modern: u16 = 0x1042;

const cfg_common: u8 = 1;
const cfg_notify: u8 = 2;
const cfg_device: u8 = 4;

pub const Cap = struct {
    cfg_type: u8,
    bar: u8,
    offset: u32,
    length: u32,
};

// Written once by probe() during boot, read-only afterwards.
var common: ?Cap = null;
var notify: ?Cap = null;
var device: ?Cap = null;

/// Scans the ECAM buses from MCFG for a virtio-block device with modern
/// capabilities; prints the evidence and stops there.
pub fn probe() bool {
    const console = arch.serial_console;
    const ecam = arch.ecam() orelse {
        console.write("BLK: no MCFG\n");
        return false;
    };
    const scan_end = @min(ecam.end_bus, @as(u8, ecam.start_bus +| 1));
    const length: usize = (@as(usize, scan_end) + 1) * 0x10_0000;
    const window = arch.mapMmioPages(ecam.base, length) orelse {
        console.write("BLK: ecam map failed\n");
        return false;
    };

    var bus: u8 = ecam.start_bus;
    while (bus <= scan_end) : (bus += 1) {
        var dev: u8 = 0;
        while (dev < 32) : (dev += 1) {
            var func: u8 = 0;
            while (func < 8) : (func += 1) {
                const id = cfgRead32(window, bus, dev, func, 0);
                if (id == 0xffff_ffff) continue;
                const vendor: u16 = @truncate(id);
                const dev_id: u16 = @truncate(id >> 16);
                if (vendor != virtio_vendor) continue;
                if (dev_id != device_legacy and dev_id != device_modern) continue;
                if (!parseCapabilities(window, bus, dev, func, dev_id)) continue;
                return true;
            }
        }
    }
    console.write("BLK: no virtio-block device\n");
    return false;
}

fn parseCapabilities(window: u64, bus: u8, dev: u8, func: u8, id: u16) bool {
    const console = arch.serial_console;
    const status = cfgRead16(window, bus, dev, func, 0x06);
    if ((status & (1 << 4)) == 0) return false; // no capability list
    var pointer = cfgRead8(window, bus, dev, func, 0x34) & 0xfc;

    var guard: usize = 0;
    while (pointer != 0 and guard < 48) : (guard += 1) {
        const cap_id = cfgRead8(window, bus, dev, func, pointer);
        if (cap_id == 0x09) { // vendor-specific: virtio structure
            const cap = Cap{
                .cfg_type = cfgRead8(window, bus, dev, func, pointer + 3),
                .bar = cfgRead8(window, bus, dev, func, pointer + 4),
                .offset = cfgRead32(window, bus, dev, func, pointer + 8),
                .length = cfgRead32(window, bus, dev, func, pointer + 12),
            };
            switch (cap.cfg_type) {
                cfg_common => common = cap,
                cfg_notify => notify = cap,
                cfg_device => device = cap,
                else => {},
            }
        }
        pointer = cfgRead8(window, bus, dev, func, pointer + 1) & 0xfc;
    }
    if (common == null or notify == null or device == null) return false;

    // Map each used BAR once; capability offsets are relative to it.
    if (!mapBar(window, bus, dev, func, common.?)) return false;
    if (!mapBar(window, bus, dev, func, notify.?)) return false;
    if (!mapBar(window, bus, dev, func, device.?)) return false;

    console.write("BLK: pci 1af4:");
    format.writeHex(console, id, 4);
    console.write(" at ");
    format.writeHex(console, bus, 2);
    console.write(":");
    format.writeHex(console, dev, 2);
    console.write(".");
    format.writeHex(console, func, 1);
    console.write(" capabilities ok\n");
    return true;
}

fn mapBar(window: u64, bus: u8, dev: u8, func: u8, cap: Cap) bool {
    const index: u8 = cap.bar;
    if (index >= 6) return false;
    const bar = cfgRead32(window, bus, dev, func, 0x10 + @as(u8, index) * 4);
    if ((bar & 1) != 0) return false; // I/O BAR: legacy path, reject
    const mem_type = (bar >> 1) & 0x3;
    var phys: u64 = bar & 0xffff_fff0;
    if (mem_type == 0x2) {
        const high = cfgRead32(window, bus, dev, func, 0x10 + (@as(u8, index) + 1) * 4);
        phys |= @as(u64, high) << 32;
    }
    _ = arch.mapMmioPages(phys, cap.length) orelse return false;
    return true;
}

fn cfgAddress(bus: u8, dev: u8, func: u8, offset: u8) u64 {
    return (@as(u64, bus) << 20) | (@as(u64, dev) << 15) | (@as(u64, func) << 12) | offset;
}

fn cfgRead8(window: u64, bus: u8, dev: u8, func: u8, offset: u8) u8 {
    const ptr: *volatile u8 = @ptrFromInt(window + cfgAddress(bus, dev, func, offset));
    return ptr.*;
}

fn cfgRead16(window: u64, bus: u8, dev: u8, func: u8, offset: u8) u16 {
    const ptr: *volatile u16 = @ptrFromInt(window + cfgAddress(bus, dev, func, offset));
    return ptr.*;
}

fn cfgRead32(window: u64, bus: u8, dev: u8, func: u8, offset: u8) u32 {
    const ptr: *volatile u32 = @ptrFromInt(window + cfgAddress(bus, dev, func, offset));
    return ptr.*;
}
