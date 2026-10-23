//! Scheduler public surface for the kernel composition root.

const sched = @import("sched.zig");

pub const onTimer = sched.onTimer;
pub const onIpi = sched.onIpi;
pub const preempt = sched.preempt;
pub const apEntry = sched.apEntry;

pub fn startKernelScheduler() bool {
    return sched.startKernelScheduler();
}

pub fn ticksNow() u64 {
    return sched.ticksNow();
}

pub fn switchesNow() u64 {
    return sched.switchesNow();
}

pub fn runSmoke() bool {
    return sched.runSmoke();
}
