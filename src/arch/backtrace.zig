//! Bounded frame-pointer backtrace for panic diagnostics.

const hal = @import("../hal/interface.zig");
const format = @import("../lib/interface.zig").format;

const Frame = extern struct {
    previous_rbp: usize,
    return_address: usize,
};

const max_frames: usize = 16;
const max_frame_delta: usize = 1 << 20;
const min_kernel_address: usize = 0xffff_8000_0000_0000;

pub noinline fn print(console: hal.Console) void {
    console.write("BACKTRACE:\n");

    var rbp = @frameAddress();
    var depth: usize = 0;
    while (depth < max_frames and rbp >= min_kernel_address) : (depth += 1) {
        // SAFETY: rbp is taken from the frame-pointer chain and must point
        // into the higher-half stack. The monotonicity and delta checks stop
        // corrupted chains before the next dereference. M0 uses Limine's stack;
        // M1 will add explicit stack bounds.
        const frame: *align(1) const Frame = @ptrFromInt(rbp);
        const ret = frame.return_address;
        if (ret == 0) break;

        console.write("  #");
        format.writeDec(console, depth);
        console.write(" ");
        format.writeHex(console, ret, 16);
        console.write("\n");

        const next = frame.previous_rbp;
        if (next <= rbp or next - rbp > max_frame_delta) break;
        rbp = next;
    }
}
