//! Scheduler public surface for the kernel composition root.

const sched = @import("sched.zig");

pub const onTimer = sched.onTimer;
pub const onIpi = sched.onIpi;
pub const preempt = sched.preempt;
pub const apEntry = sched.apEntry;

pub fn runSmoke() bool {
    return sched.runSmoke();
}
