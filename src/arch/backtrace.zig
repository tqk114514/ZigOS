//! Bounded frame-pointer backtrace for panic diagnostics.

const hal = @import("../hal/interface.zig");
const format = @import("../lib/interface.zig").format;

const Frame = extern struct {
    previous_rbp: usize,
    return_address: usize,
};

const max_frames: usize = 16;
const max_frame_delta: usize = 1 << 20;

extern var __stack_bottom: u8;
extern var __stack_top: u8;

pub noinline fn print(console: hal.Console) void {
    console.write("BACKTRACE:\n");
    const stack_low = @intFromPtr(&__stack_bottom);
    const stack_high = @intFromPtr(&__stack_top);

    var rbp = @frameAddress();
    var depth: usize = 0;
    while (depth < max_frames and rbp >= stack_low and rbp < stack_high) : (depth += 1) {
        // SAFETY: rbp is constrained to the fixed 64KiB kernel stack; the
        // monotonicity and delta checks stop corrupted chains before the next
        // dereference. M1 adds guard pages and IST stacks.
        const frame: *align(1) const Frame = @ptrFromInt(rbp);
        const ret = frame.return_address;
        if (ret == 0) break;

        console.write("  #");
        format.writeDec(console, depth);
        console.write(" ");
        format.writeHex(console, ret, 16);
        console.write("\n");

        const next = frame.previous_rbp;
        if (next <= rbp or next - rbp > max_frame_delta or next >= stack_high) break;
        rbp = next;
    }
}
