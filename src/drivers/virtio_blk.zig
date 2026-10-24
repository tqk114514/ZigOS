//! virtio-blk over modern virtio 1.0 PCI: ECAM enumeration, capability
//! parsing, split-queue setup, and a polled single-sector read.

const hal = @import("../hal/interface.zig");
const arch = @import("../arch/interface.zig");
const format = @import("../lib/interface.zig").format;

const virtio_vendor: u16 = 0x1af4;
const device_legacy: u16 = 0x1001; // transitional; modern caps still required
const device_modern: u16 = 0x1042;

const cfg_common: u8 = 1;
const cfg_notify: u8 = 2;
const cfg_device: u8 = 4;

const status_acknowledge: u8 = 1;
const status_driver: u8 = 2;
const status_driver_ok: u8 = 4;
const status_features_ok: u8 = 8;
const status_failed: u8 = 0x80;

// virtio_pci_common_cfg. The 64-bit fields are accessed as two 32-bit reads.
const common_device_feature_select: usize = 0x00;
const common_device_feature: usize = 0x04;
const common_driver_feature_select: usize = 0x08;
const common_driver_feature: usize = 0x0c;
const common_num_queues: usize = 0x12;
const common_device_status: usize = 0x14;
const common_queue_select: usize = 0x16;
const common_queue_size: usize = 0x18;
const common_queue_enable: usize = 0x1c;
const common_queue_notify_off: usize = 0x1e;
const common_queue_desc: usize = 0x20;
const common_queue_avail: usize = 0x28;
const common_queue_used: usize = 0x30;

const device_capacity: usize = 0x00;

const virtio_blk_in: u32 = 0;

const desc_next: u16 = 1;
const desc_write: u16 = 2;

const queue_size: u16 = 16;
const sector_size: u32 = 512;
const read_timeout_ticks: u64 = 4_000_000_000;

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const Avail = extern struct {
    flags: u16,
    idx: u16,
    ring: [queue_size]u16,
};

const UsedElem = extern struct {
    id: u32,
    len: u32,
};

const Used = extern struct {
    flags: u16,
    idx: u16,
    ring: [queue_size]UsedElem,
};

const RequestHeader = extern struct {
    kind: u32,
    reserved: u32,
    sector: u64,
};

pub const Cap = struct {
    cfg_type: u8,
    bar: u8,
    offset: u32,
    length: u32,
    virt: u64 = 0,
    multiplier: u32 = 0,
};

const Caps = struct {
    common: Cap,
    notify: Cap,
    device: Cap,
};

const Region = struct {
    phys: u64,
    virt: u64,
};

const Queue = struct {
    size: u16,
    desc: [*]Desc,
    avail: *Avail,
    used: *Used,
    last_used: u16,
    notify: u64,
    req_phys: u64,
    req_virt: u64,
    data_phys: u64,
    data_virt: u64,
};

// Boot-once state: probe() and init() write it during boot; it is read-only
// afterwards. Queue frames live for the device's lifetime.
var common: ?Cap = null;
var notify: ?Cap = null;
var device: ?Cap = null;
var queue: ?Queue = null;
var capacity: u64 = 0;

/// Scans the ECAM buses from MCFG for a virtio-block device with modern
/// capabilities and maps its BARs. Queue setup happens in init().
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
                const caps = parseCapabilities(window, bus, dev, func) orelse continue;
                common = caps.common;
                notify = caps.notify;
                device = caps.device;
                console.write("BLK: pci 1af4:");
                format.writeHex(console, dev_id, 4);
                console.write(" at ");
                format.writeHex(console, bus, 2);
                console.write(":");
                format.writeHex(console, dev, 2);
                console.write(".");
                format.writeHex(console, func, 1);
                console.write(" capabilities ok\n");
                return true;
            }
        }
    }
    console.write("BLK: no virtio-block device\n");
    return false;
}

fn parseCapabilities(window: u64, bus: u8, dev: u8, func: u8) ?Caps {
    const status = cfgRead16(window, bus, dev, func, 0x06);
    if ((status & (1 << 4)) == 0) return null; // no capability list
    var pointer = cfgRead8(window, bus, dev, func, 0x34) & 0xfc;
    var common_cap: ?Cap = null;
    var notify_cap: ?Cap = null;
    var device_cap: ?Cap = null;

    var guard: usize = 0;
    while (pointer != 0 and guard < 48) : (guard += 1) {
        if (pointer > 0xf0) return null; // no room for a 20-byte virtio cap
        if (cfgRead8(window, bus, dev, func, pointer) == 0x09) { // virtio structure
            const cfg_type = cfgRead8(window, bus, dev, func, pointer + 3);
            const cap = Cap{
                .cfg_type = cfg_type,
                .bar = cfgRead8(window, bus, dev, func, pointer + 4),
                .offset = cfgRead32(window, bus, dev, func, pointer + 8),
                .length = cfgRead32(window, bus, dev, func, pointer + 12),
                .multiplier = if (cfg_type == cfg_notify)
                    cfgRead32(window, bus, dev, func, pointer + 16)
                else
                    0,
            };
            switch (cfg_type) {
                cfg_common => common_cap = cap,
                cfg_notify => notify_cap = cap,
                cfg_device => device_cap = cap,
                else => {},
            }
        }
        pointer = cfgRead8(window, bus, dev, func, pointer + 1) & 0xfc;
    }

    var found_common = common_cap orelse return null;
    var found_notify = notify_cap orelse return null;
    var found_device = device_cap orelse return null;
    found_common.virt = mapBar(window, bus, dev, func, found_common) orelse return null;
    found_notify.virt = mapBar(window, bus, dev, func, found_notify) orelse return null;
    found_device.virt = mapBar(window, bus, dev, func, found_device) orelse return null;
    return .{ .common = found_common, .notify = found_notify, .device = found_device };
}

fn mapBar(window: u64, bus: u8, dev: u8, func: u8, cap: Cap) ?u64 {
    if (cap.bar >= 6) return null;
    const bar = cfgRead32(window, bus, dev, func, @as(u8, 0x10) + cap.bar * 4);
    if ((bar & 1) != 0) return null; // I/O BAR: legacy path, reject
    const mem_type = (bar >> 1) & 0x3;
    var phys: u64 = bar & 0xffff_fff0;
    if (mem_type == 0x2) {
        const high = cfgRead32(window, bus, dev, func, @as(u8, 0x10) + (cap.bar + 1) * 4);
        phys |= @as(u64, high) << 32;
    }
    return arch.mapMmioPages(phys, @as(usize, cap.offset) + cap.length);
}

/// Negotiates virtio 1.0, brings up queue 0, and records the capacity.
pub fn init() bool {
    if (queue != null) return true;
    const cap = common orelse return false;
    if (cap.virt == 0) return false;
    const c = cap.virt + cap.offset;

    write8(c, common_device_status, 0);
    write8(c, common_device_status, status_acknowledge);
    write8(c, common_device_status, status_acknowledge | status_driver);

    write32(c, common_device_feature_select, 1);
    const features_high = read32(c, common_device_feature);
    if ((features_high & 1) == 0) return fail(c); // VIRTIO_F_VERSION_1

    write32(c, common_driver_feature_select, 0);
    write32(c, common_driver_feature, 0);
    write32(c, common_driver_feature_select, 1);
    write32(c, common_driver_feature, 1);

    write8(c, common_device_status, status_acknowledge | status_driver | status_features_ok);
    if ((read8(c, common_device_status) & status_features_ok) == 0) return false;

    if (read16(c, common_num_queues) == 0) return fail(c);
    write16(c, common_queue_select, 0);
    if (read16(c, common_queue_size) < queue_size) return fail(c);
    write16(c, common_queue_size, queue_size);

    const desc_region = allocRegion() orelse return fail(c);
    const avail_region = allocRegion() orelse return fail(c);
    const used_region = allocRegion() orelse return fail(c);
    const req_region = allocRegion() orelse return fail(c);
    const data_region = allocRegion() orelse return fail(c);

    const desc: [*]Desc = @ptrFromInt(desc_region.virt);
    const avail: *Avail = @ptrFromInt(avail_region.virt);
    const used: *Used = @ptrFromInt(used_region.virt);
    avail.flags = 0;
    avail.idx = 0;
    used.flags = 0;
    used.idx = 0;

    write64(c, common_queue_desc, desc_region.phys);
    write64(c, common_queue_avail, avail_region.phys);
    write64(c, common_queue_used, used_region.phys);
    write16(c, common_queue_enable, 1);
    if (read16(c, common_queue_enable) != 1) return fail(c);

    const notify_cap = notify orelse return fail(c);
    const notify_off = read16(c, common_queue_notify_off);
    const notify_address = notify_cap.virt + notify_cap.offset +
        @as(u64, notify_off) * notify_cap.multiplier;

    const device_cap = device orelse return fail(c);
    capacity = read64(device_cap.virt + device_cap.offset, device_capacity);
    if (capacity == 0) return fail(c);

    queue = .{
        .size = queue_size,
        .desc = desc,
        .avail = avail,
        .used = used,
        .last_used = 0,
        .notify = notify_address,
        .req_phys = req_region.phys,
        .req_virt = req_region.virt,
        .data_phys = data_region.phys,
        .data_virt = data_region.virt,
    };

    write8(c, common_device_status, status_acknowledge | status_driver | status_features_ok | status_driver_ok);
    return true;
}

/// Reads one sector into `buf`, which must be exactly one sector long.
/// Completion is polled; interrupts are not used yet.
pub fn read(lba: u64, buf: []u8) bool {
    const q = if (queue) |*value| value else return false;
    if (buf.len != sector_size or lba >= capacity) return false;

    const header: *RequestHeader = @ptrFromInt(q.req_virt);
    header.* = .{ .kind = virtio_blk_in, .reserved = 0, .sector = lba };
    const status: *u8 = @ptrFromInt(q.req_virt + @sizeOf(RequestHeader));
    status.* = 0xff;

    q.desc[0] = .{
        .addr = q.req_phys,
        .len = @sizeOf(RequestHeader),
        .flags = desc_next,
        .next = 1,
    };
    q.desc[1] = .{
        .addr = q.data_phys,
        .len = sector_size,
        .flags = desc_next | desc_write,
        .next = 2,
    };
    q.desc[2] = .{
        .addr = q.req_phys + @sizeOf(RequestHeader),
        .len = 1,
        .flags = desc_write,
        .next = 0,
    };

    const avail_idx = @atomicLoad(u16, &q.avail.idx, .monotonic);
    q.avail.ring[avail_idx % q.size] = 0;
    @atomicStore(u16, &q.avail.idx, avail_idx +% 1, .release);
    write16(q.notify, 0, 0); // queue index 0

    const deadline = arch.rdtsc() + read_timeout_ticks;
    var used_idx = @atomicLoad(u16, &q.used.idx, .acquire);
    while (used_idx == q.last_used) {
        if (arch.rdtsc() > deadline) {
            // The device may still own the descriptors; retire it instead of
            // letting the next request reuse the chain.
            if (common) |cap| _ = fail(cap.virt + cap.offset);
            queue = null;
            return false;
        }
        arch.cpuPause();
        used_idx = @atomicLoad(u16, &q.used.idx, .acquire);
    }

    const elem = q.used.ring[(used_idx -% 1) % q.size];
    q.last_used = used_idx;
    if (elem.id != 0 or status.* != 0) return false;

    const data: [*]const u8 = @ptrFromInt(q.data_virt);
    @memcpy(buf, data[0..buf.len]);
    return true;
}

pub fn blockDevice() ?hal.BlockDevice {
    if (queue == null) return null;
    return .{
        .ctx = @ptrCast(&queue),
        .read_fn = readEntry,
        .sector_size = sector_size,
    };
}

fn readEntry(_: *anyopaque, lba: u64, buf: []u8) bool {
    return read(lba, buf);
}

/// Smoke path: init the device, read sector 0 through the HAL interface, and
/// compare it with the initramfs image Limine loaded as a module.
pub fn runSmoke() bool {
    const console = arch.serial_console;
    if (!init()) {
        console.write("BLK: device init failed\n");
        return false;
    }
    const dev = blockDevice() orelse return false;
    console.write("BLK: capacity ");
    format.writeDec(console, capacity);
    console.write(" sectors\n");

    var buf: [sector_size]u8 = undefined;
    if (!dev.read(0, &buf)) {
        console.write("BLK: read failed\n");
        return false;
    }
    const image = arch.moduleImage("/initramfs.img") orelse {
        console.write("BLK: no initramfs module to compare\n");
        return false;
    };
    const compared = @min(image.len, sector_size);
    var index: usize = 0;
    while (index < compared) : (index += 1) {
        if (buf[index] != image[index]) {
            console.write("BLK: sector 0 mismatch at ");
            format.writeDec(console, index);
            console.write("\n");
            return false;
        }
    }
    console.write("BLK: read sector 0 ok (");
    format.writeDec(console, compared);
    console.write(" bytes match)\n");
    return true;
}

fn allocRegion() ?Region {
    const phys = arch.allocFrame() orelse return null;
    const virt = arch.physToVirt(phys) orelse return null;
    return .{ .phys = phys, .virt = virt };
}

fn fail(c: u64) bool {
    const status = read8(c, common_device_status);
    write8(c, common_device_status, status | status_failed);
    return false;
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

fn read8(base: u64, offset: usize) u8 {
    const ptr: *volatile u8 = @ptrFromInt(base + offset);
    return ptr.*;
}

fn read16(base: u64, offset: usize) u16 {
    const ptr: *volatile u16 = @ptrFromInt(base + offset);
    return ptr.*;
}

fn read32(base: u64, offset: usize) u32 {
    const ptr: *volatile u32 = @ptrFromInt(base + offset);
    return ptr.*;
}

fn read64(base: u64, offset: usize) u64 {
    return @as(u64, read32(base, offset)) | (@as(u64, read32(base, offset + 4)) << 32);
}

fn write8(base: u64, offset: usize, value: u8) void {
    const ptr: *volatile u8 = @ptrFromInt(base + offset);
    ptr.* = value;
}

fn write16(base: u64, offset: usize, value: u16) void {
    const ptr: *volatile u16 = @ptrFromInt(base + offset);
    ptr.* = value;
}

fn write32(base: u64, offset: usize, value: u32) void {
    const ptr: *volatile u32 = @ptrFromInt(base + offset);
    ptr.* = value;
}

fn write64(base: u64, offset: usize, value: u64) void {
    write32(base, offset, @truncate(value));
    write32(base, offset + 4, @truncate(value >> 32));
}
