//! Kernel context switch: saves the callee-saved registers and swaps stacks.

extern fn switchTo(save: *usize, next_rsp: usize) callconv(.c) void;

pub fn switchContext(save: *usize, next_rsp: usize) void {
    // SAFETY: called with interrupts disabled; next_rsp is a stack prepared by
    // the scheduler (thread initial frame or a saved context).
    switchTo(save, next_rsp);
}
