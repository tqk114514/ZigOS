//! Block and character device drivers.

const hal = @import("../hal/interface.zig");
const virtio_blk = @import("virtio_blk.zig");

pub fn probe() bool {
    return virtio_blk.probe();
}

pub fn blockDevice() ?hal.BlockDevice {
    return virtio_blk.blockDevice();
}

pub fn runSmoke() bool {
    return virtio_blk.runSmoke();
}
