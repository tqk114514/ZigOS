const kernel = @import("kernel/init.zig");

pub const panic = @import("kernel/panic.zig");

export fn kmain() callconv(.c) noreturn {
    kernel.main();
}
