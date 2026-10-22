//! IRQ-safe spinlock. Every acquisition disables interrupts on the local CPU
//! and release restores the previous interrupt state, so a lock can never
//! deadlock against an interrupt handler on the same CPU.

const cpu = @import("cpu.zig");

const free: u32 = 0;
const held: u32 = 1;

pub const Lock = struct {
    state: u32 = free,

    /// Waits for the lock and returns the interrupt state to restore later.
    pub fn acquire(self: *Lock) IrqState {
        const irq: IrqState = .{ .enabled = cpu.saveAndDisableInterrupts() };
        while (true) {
            if (@atomicLoad(u32, &self.state, .monotonic) == free and
                @cmpxchgWeak(u32, &self.state, free, held, .acquire, .monotonic) == null)
            {
                return irq;
            }
            while (@atomicLoad(u32, &self.state, .monotonic) != free) cpu.pause();
        }
    }

    pub fn release(self: *Lock, irq: IrqState) void {
        @atomicStore(u32, &self.state, free, .release);
        cpu.restoreInterrupts(irq.enabled);
    }
};

pub const IrqState = struct {
    enabled: bool,
};
