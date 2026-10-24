//! Block device drivers.

const virtio_blk = @import("virtio_blk.zig");

pub fn probe() bool {
    return virtio_blk.probe();
}
