//! Preemptive round-robin kernel threads on per-CPU run queues. Static thread
//! pool and stacks; no allocation anywhere. The kernel composition root
//! registers the timer/IPI vector handlers, the IRQ-exit preemption hook, and
//! apEntry for the APs before interrupts are enabled.

const arch = @import("../arch/interface.zig");
const format = @import("../lib/interface.zig").format;

const max_threads: usize = 24;
const stack_size: usize = 16 * 1024;
const stack_stride: u64 = 0x5000; // 4 KiB guard + 16 KiB stack
const stack_window: u64 = 0xffff_d000_0000_0000;
const idle_stack_size: usize = 4 * 1024;
const quantum_ticks: u32 = 1;
const worker_target: u64 = 200_000;
const workers_per_cpu: usize = 2;
const deadline_ticks: u64 = 4_000_000_000;

const State = enum { free, runnable, running, blocked };

pub const Thread = struct {
    rsp: usize = 0,
    entry: ?*const fn () callconv(.c) void = null,
    state: State = .free,
    id: usize = 0,
    cpu: usize = 0,
    counter: u64 = 0,
    wake_at: u64 = 0,
    woke_at: u64 = 0,
    verified: u32 = 0, // atomic
    done: u32 = 0, // atomic
};

const Queue = struct {
    lock: arch.Lock align(64) = .{},
    ring: [max_threads]*Thread = undefined,
    head: usize = 0,
    count: usize = 0,
    current: *Thread = undefined,
    idle: *Thread = undefined,
    ticks_left: u32 = 0,
    need_resched: bool = false,
    switches: u64 = 0,
    ready: u32 = 0, // atomic; set once this CPU's scheduler runs
    reap: ?*Thread = null, // zombie to release on this CPU (queue lock)
};

// Boot-once state: each CPU touches only its own queue (under its lock) plus
// the shared pool (under pool_lock). `ready` is the release/acquire handoff.
var threads: [max_threads]Thread = defaultArray(Thread, max_threads);
var stacks_mapped: bool = false;
var idles: [arch.cpu_limit]Thread = defaultArray(Thread, arch.cpu_limit);
var idle_stacks: [arch.cpu_limit][idle_stack_size]u8 align(16) = undefined;
var queues: [arch.cpu_limit]Queue = defaultArray(Queue, arch.cpu_limit);
var pool_lock: arch.Lock align(64) = .{};
var workers: [arch.cpu_limit * workers_per_cpu]?*Thread = nullArray(arch.cpu_limit * workers_per_cpu);
var worker_count: usize = 0;

// Sleepers and wait queues. Lock order: sleep/wq -> per-CPU queue; never the
// reverse. Timer handlers run with interrupts disabled.
var sleep_lock: arch.Lock align(64) = .{};
var sleepers: [max_threads]?*Thread = nullArray(max_threads);
var sleeper_count: u32 = 0; // atomic mirror, for the timer fast path
var ticks: u64 = 0; // atomic-add by timer handlers

pub const WaitQueue = struct {
    lock: arch.Lock align(64) = .{},
    waiters: [max_threads]?*Thread = nullArray(max_threads),
    count: usize = 0,

    /// Blocks the current thread until wakeOne/wakeAll.
    pub fn wait(self: *WaitQueue) void {
        const was_enabled = arch.saveAndDisableInterrupts();
        const irq = self.lock.acquire();
        const cpu = arch.cpuIndex();
        const t = queues[cpu].current;
        // An idle thread has nowhere to block; treat that as a no-op.
        if (t == queues[cpu].idle or self.count >= max_threads) {
            self.lock.release(irq);
            arch.restoreInterrupts(was_enabled);
            return;
        }
        self.waiters[self.count] = t;
        self.count += 1;
        t.state = .blocked;
        self.lock.release(irq);
        blockCurrent();
        arch.restoreInterrupts(was_enabled);
    }

    /// Wakes one waiter on its home CPU; returns false when empty.
    pub fn wakeOne(self: *WaitQueue) bool {
        const was_enabled = arch.saveAndDisableInterrupts();
        const irq = self.lock.acquire();
        if (self.count == 0) {
            self.lock.release(irq);
            arch.restoreInterrupts(was_enabled);
            return false;
        }
        const t = self.waiters[0].?;
        var i: usize = 1;
        while (i < self.count) : (i += 1) self.waiters[i - 1] = self.waiters[i];
        self.count -= 1;
        self.waiters[self.count] = null;
        self.lock.release(irq);
        makeRunnable(t);
        arch.restoreInterrupts(was_enabled);
        return true;
    }
};

var smoke_wq: WaitQueue = .{};

/// Blocks the current thread for at least n timer ticks.
pub fn sleepTicks(n: u64) void {
    const was_enabled = arch.saveAndDisableInterrupts();
    const irq = sleep_lock.acquire();
    const cpu = arch.cpuIndex();
    const t = queues[cpu].current;
    var slot: ?usize = null;
    for (&sleepers, 0..) |*entry, i| {
        if (entry.* == null) {
            slot = i;
            break;
        }
    }
    if (slot == null or t == queues[cpu].idle) {
        sleep_lock.release(irq);
        arch.restoreInterrupts(was_enabled);
        return;
    }
    sleepers[slot.?] = t;
    _ = @atomicRmw(u32, &sleeper_count, .Add, 1, .monotonic);
    t.state = .blocked;
    t.wake_at = @atomicLoad(u64, &ticks, .monotonic) + n;
    sleep_lock.release(irq);
    blockCurrent();
    // Resumed by wakeDue on some CPU's timer tick.
    t.state = .running;
    t.woke_at = @atomicLoad(u64, &ticks, .monotonic);
    arch.restoreInterrupts(was_enabled);
}

fn defaultArray(comptime T: type, comptime n: usize) [n]T {
    var out: [n]T = undefined;
    for (&out) |*slot| slot.* = .{};
    return out;
}

fn nullArray(comptime n: usize) [n]?*Thread {
    var out: [n]?*Thread = undefined;
    for (&out) |*slot| slot.* = null;
    return out;
}

/// Starts scheduling on the current CPU with the boot context as current.
/// Maps the guarded per-thread stack window once (boot CPU).
pub fn ensureStacks() bool {
    if (stacks_mapped) return true;
    var id: usize = 0;
    while (id < max_threads) : (id += 1) {
        var page: u64 = 0;
        while (page < 4) : (page += 1) {
            const virt = stack_window + id * stack_stride + 0x1000 + page * 0x1000;
            if (!arch.mapKernelPage(virt)) return false;
        }
    }
    stacks_mapped = true;
    return true;
}

pub fn waitApReady() bool {
    const deadline = arch.rdtsc() + deadline_ticks;
    const self = arch.cpuIndex();
    var cpu: usize = 0;
    while (cpu < arch.cpuCount()) : (cpu += 1) {
        if (cpu == self) continue;
        while (@atomicLoad(u32, &queues[cpu].ready, .acquire) == 0) {
            if (arch.rdtsc() > deadline) return false;
            arch.cpuPause();
        }
    }
    return true;
}

pub fn startKernelScheduler() bool {
    if (!ensureStacks()) return false;
    const cpu = arch.cpuIndex();
    if (cpu >= arch.cpu_limit or !setupCpu(cpu)) return false;
    const boot = &threads[0];
    if (boot.entry == null) {
        boot.entry = &idleLoop;
        boot.cpu = cpu;
        boot.id = 0;
    }
    queues[cpu].current = boot;
    queues[cpu].ticks_left = quantum_ticks;
    if (!arch.startLocalTimer()) return false;
    arch.enableInterrupts();
    return true;
}

pub fn ticksNow() u64 {
    return @atomicLoad(u64, &ticks, .monotonic);
}

pub fn switchesNow() u64 {
    return @atomicLoad(u64, &queues[arch.cpuIndex()].switches, .monotonic);
}

pub fn onTimer() callconv(.c) void {
    arch.eoi();
    _ = @atomicRmw(u64, &ticks, .Add, 1, .monotonic);
    wakeDue();
    const q = &queues[arch.cpuIndex()];
    if (q.need_resched) return;
    if (q.ticks_left > 0) q.ticks_left -= 1;
    if (q.ticks_left == 0) {
        q.need_resched = true;
        q.ticks_left = quantum_ticks;
    }
}

pub fn onIpi() callconv(.c) void {
    arch.eoi();
    queues[arch.cpuIndex()].need_resched = true;
}

/// IRQ-exit hook: switches threads when this CPU asked for a reschedule.
pub fn preempt() callconv(.c) void {
    const q = &queues[arch.cpuIndex()];
    if (!q.need_resched) return;
    q.need_resched = false;

    const irq = q.lock.acquire();
    const prev = q.current;
    var next: ?*Thread = takeNext(q);
    if (next == null and prev != q.idle) next = q.idle;
    if (next == null) {
        q.lock.release(irq);
        return;
    }
    const target = next.?;
    if (prev != q.idle) {
        prev.state = .runnable;
        enqueue(q, prev);
    }
    target.state = .running;
    q.current = target;
    @atomicStore(u64, &q.switches, @atomicLoad(u64, &q.switches, .monotonic) + 1, .monotonic);
    q.ticks_left = quantum_ticks;
    q.lock.release(irq);
    arch.switchContext(&prev.rsp, target.rsp);
}

/// Enters the scheduler on an AP; never returns.
pub fn apEntry() callconv(.c) noreturn {
    const cpu = arch.cpuIndex();
    if (cpu >= arch.cpu_limit or !setupCpu(cpu)) arch.halt();

    const q = &queues[cpu];
    q.current = q.idle;
    q.ticks_left = quantum_ticks;
    if (!arch.startLocalTimer()) arch.halt();
    @atomicStore(u32, &q.ready, 1, .release);

    var abandoned: usize = 0;
    arch.disableInterrupts();
    arch.switchContext(&abandoned, q.idle.rsp);
    arch.halt();
}

fn setupCpu(cpu: usize) bool {
    const idle = &idles[cpu];
    idle.id = cpu;
    idle.cpu = cpu;
    prepareOn(idle, @intFromPtr(&idle_stacks[cpu]) + idle_stack_size, &idleLoop);
    queues[cpu].idle = idle;
    return true;
}

/// Smoke: two compute workers per CPU plus a controller on the boot CPU.
pub fn runSmoke() bool {
    const console = arch.serial_console;
    if (!ensureStacks()) return false;
    // Guard pages must stay unmapped; stack bottoms must be live.
    var check: usize = 1;
    while (check < max_threads) : (check += 1) {
        const guard = stack_window + check * stack_stride;
        if (arch.translateVirtual(guard) != null) return false;
        if (arch.translateVirtual(guard + 0x1000) == null) return false;
    }
    console.write("SCHED: guard pages ok\n");
    const ncpus = arch.cpuCount();
    const boot_cpu = arch.cpuIndex();
    if (ncpus == 0 or ncpus > arch.cpu_limit) return false;

    var cpu: usize = 0;
    while (cpu < arch.cpu_limit) : (cpu += 1) {
        if (!setupCpu(cpu)) return false;
    }

    // The boot context is this CPU's running thread.
    const boot = &threads[0];
    boot.entry = &idleLoop;
    boot.cpu = boot_cpu;
    boot.id = 0;
    queues[boot_cpu].current = boot;
    queues[boot_cpu].ticks_left = quantum_ticks;

    // Wait until every AP scheduler is live before handing it work.
    const ready_deadline = arch.rdtsc() + deadline_ticks;
    cpu = 0;
    while (cpu < ncpus) : (cpu += 1) {
        if (cpu == boot_cpu) continue;
        while (@atomicLoad(u32, &queues[cpu].ready, .acquire) == 0) {
            if (arch.rdtsc() > ready_deadline) {
                console.write("SCHED: AP scheduler not ready\n");
                return false;
            }
            arch.cpuPause();
        }
    }

    worker_count = 0;
    cpu = 0;
    while (cpu < ncpus) : (cpu += 1) {
        var worker: usize = 0;
        while (worker < workers_per_cpu) : (worker += 1) {
            const t = spawn(&workerEntry, cpu) orelse return false;
            workers[worker_count] = t;
            worker_count += 1;
        }
    }

    if (!arch.startLocalTimer()) return false;
    arch.enableInterrupts();

    const deadline = arch.rdtsc() + deadline_ticks;
    while (true) {
        var pending = false;
        var i: usize = 0;
        while (i < worker_count) : (i += 1) {
            const t = workers[i].?;
            if (@atomicLoad(u32, &t.done, .acquire) == 0) {
                pending = true;
                break;
            }
        }
        if (!pending) break;
        if (arch.rdtsc() > deadline) {
            console.write("SCHED: workers did not finish\n");
            return false;
        }
        arch.cpuPause();
    }

    cpu = 0;
    while (cpu < ncpus) : (cpu += 1) {
        const switches = @atomicLoad(u64, &queues[cpu].switches, .monotonic);
        if (switches == 0) return false;
        console.write("SCHED: cpu ");
        format.writeDec(console, cpu);
        console.write(" switches ");
        format.writeDec(console, switches);
        console.write("\n");
    }
    var i: usize = 0;
    while (i < worker_count) : (i += 1) {
        const t = workers[i].?;
        if (t.counter < worker_target) return false;
        console.write("SCHED: thread ");
        format.writeDec(console, t.id);
        console.write(" cpu ");
        format.writeDec(console, t.cpu);
        console.write(" counter ");
        format.writeDec(console, t.counter);
        console.write("\n");
    }
    // Phase 2: timed sleep and a cross-CPU wait-queue wake. Each participant
    // reports through its own done/verified fields.
    const sleeper = spawn(&sleeperEntry, ncpus - 1) orelse return false;
    const waiter = spawn(&waiterEntry, (ncpus - 1) / 2) orelse return false;
    const waker = spawn(&wakerEntry, ncpus - 1) orelse return false;
    const wake_deadline = arch.rdtsc() + deadline_ticks;
    while (@atomicLoad(u32, &sleeper.done, .acquire) == 0 or
        @atomicLoad(u32, &waiter.done, .acquire) == 0 or
        @atomicLoad(u32, &waker.done, .acquire) == 0)
    {
        if (arch.rdtsc() > wake_deadline) {
            console.write("SCHED: sleep/wake did not finish\n");
            return false;
        }
        arch.cpuPause();
    }
    if (@atomicLoad(u32, &sleeper.verified, .acquire) == 0) return false;
    if (sleeper.woke_at < 2) return false;
    if (@atomicLoad(u32, &waiter.verified, .acquire) == 0) return false;
    console.write("SCHED: sleep ok\n");
    console.write("SCHED: wake ok\n");
    return true;
}

fn sleeperEntry() callconv(.c) void {
    const t = queues[arch.cpuIndex()].current;
    sleepTicks(2);
    if (t.woke_at >= 2) @atomicStore(u32, &t.verified, 1, .release);
    @atomicStore(u32, &t.done, 1, .release);
    while (true) {
        asm volatile ("hlt");
    }
}

fn waiterEntry() callconv(.c) void {
    const t = queues[arch.cpuIndex()].current;
    smoke_wq.wait();
    @atomicStore(u32, &t.verified, 1, .release);
    @atomicStore(u32, &t.done, 1, .release);
    while (true) {
        asm volatile ("hlt");
    }
}

fn wakerEntry() callconv(.c) void {
    const t = queues[arch.cpuIndex()].current;
    sleepTicks(2);
    _ = smoke_wq.wakeOne();
    @atomicStore(u32, &t.done, 1, .release);
    while (true) {
        asm volatile ("hlt");
    }
}

pub fn spawn(entry: *const fn () callconv(.c) void, cpu: usize) ?*Thread {
    const pool_irq = pool_lock.acquire();
    var slot: ?*Thread = null;
    for (&threads) |*t| {
        if (t.entry == null) {
            slot = t;
            break;
        }
    }
    const t = slot orelse {
        pool_lock.release(pool_irq);
        return null;
    };
    t.entry = entry;
    t.state = .runnable;
    pool_lock.release(pool_irq);

    t.id = (@intFromPtr(t) - @intFromPtr(&threads[0])) / @sizeOf(Thread);
    t.cpu = cpu;
    t.counter = 0;
    t.done = 0;
    prepareOn(t, @intCast(stackTop(t.id)), entry);

    const q = &queues[cpu];
    const irq = q.lock.acquire();
    enqueue(q, t);
    q.lock.release(irq);
    if (cpu != arch.cpuIndex()) arch.sendIpi(arch.apicIdOf(cpu), arch.ipi_vector);
    return t;
}

fn prepareOn(t: *Thread, stack_top: usize, entry: *const fn () callconv(.c) void) void {
    const top = stack_top & ~@as(usize, 15);
    // switchTo pops six callee-saved registers and then returns; the saved
    // frame starts 64 bytes below the top so the entry sees rsp % 16 == 8.
    const base = top - 64;
    const regs: *[6]usize = @ptrFromInt(base);
    regs.* = .{ 0, 0, 0, 0, 0, 0 };
    const ret_slot: *usize = @ptrFromInt(top - 16);
    ret_slot.* = @intFromPtr(&threadTrampoline);
    t.rsp = base;
    t.entry = entry;
}

/// Switches away from the current (already-blocked) thread. IF stays off; the
/// caller restores its saved interrupt state after being woken.
fn blockCurrent() void {
    const cpu = arch.cpuIndex();
    const q = &queues[cpu];
    const irq = q.lock.acquire();
    const prev = q.current;
    if (prev == q.idle) {
        q.lock.release(irq);
        return;
    }
    q.current = takeNext(q) orelse q.idle;
    q.need_resched = false;
    @atomicStore(u64, &q.switches, @atomicLoad(u64, &q.switches, .monotonic) + 1, .monotonic);
    q.ticks_left = quantum_ticks;
    q.lock.release(irq);
    arch.switchContext(&prev.rsp, q.current.rsp);
}

fn makeRunnable(t: *Thread) void {
    const cpu = t.cpu;
    const q = &queues[cpu];
    const irq = q.lock.acquire();
    t.state = .runnable;
    enqueue(q, t);
    q.lock.release(irq);
    if (cpu != arch.cpuIndex()) arch.sendIpi(arch.apicIdOf(cpu), arch.ipi_vector);
}

fn wakeDue() void {
    if (@atomicLoad(u32, &sleeper_count, .monotonic) == 0) return;
    const irq = sleep_lock.acquire();
    const now = @atomicLoad(u64, &ticks, .monotonic);
    for (&sleepers) |*slot| {
        const t = slot.* orelse continue;
        if (t.wake_at > now) continue;
        slot.* = null;
        _ = @atomicRmw(u32, &sleeper_count, .Sub, 1, .monotonic);
        makeRunnable(t);
    }
    sleep_lock.release(irq);
}

fn stackTop(id: usize) u64 {
    return stack_window + id * stack_stride + 0x1000 + stack_size;
}

fn enqueue(q: *Queue, t: *Thread) void {
    q.ring[(q.head + q.count) % max_threads] = t;
    q.count += 1;
}

fn takeNext(q: *Queue) ?*Thread {
    if (q.count == 0) return null;
    const t = q.ring[q.head];
    q.head = (q.head + 1) % max_threads;
    q.count -= 1;
    return t;
}

fn threadTrampoline() callconv(.c) noreturn {
    // Entered with interrupts disabled from switchTo; the thread's own entry
    // runs with them on so the timer can preempt it.
    const t = queues[arch.cpuIndex()].current;
    arch.enableInterrupts();
    const entry = t.entry orelse idleLoop;
    entry();
    threadExit();
}

fn threadExit() noreturn {
    const cpu = arch.cpuIndex();
    const q = &queues[cpu];
    const irq = q.lock.acquire();
    const prev = q.current;
    // The stack is still in use until the switch away; idle reaps it later.
    q.reap = prev;
    q.current = q.idle;
    @atomicStore(u64, &q.switches, @atomicLoad(u64, &q.switches, .monotonic) + 1, .monotonic);
    q.ticks_left = quantum_ticks;
    q.lock.release(irq);
    arch.switchContext(&prev.rsp, q.idle.rsp);
    arch.halt();
}

fn idleLoop() callconv(.c) noreturn {
    arch.enableInterrupts();
    while (true) {
        reapZombie(arch.cpuIndex());
        // SAFETY: idle with interrupts enabled; timer/IPI wake it.
        asm volatile ("hlt");
    }
}

fn reapZombie(cpu: usize) void {
    const q = &queues[cpu];
    const zombie = q.reap orelse return;
    q.reap = null;
    const pool_irq = pool_lock.acquire();
    // Only the exited thread's slot is touched; its stack is off-CPU now.
    if (zombie.entry != null) {
        zombie.entry = null;
        zombie.state = .free;
    }
    pool_lock.release(pool_irq);
}

fn workerEntry() callconv(.c) void {
    const t = queues[arch.cpuIndex()].current;
    while (t.counter < worker_target) {
        t.counter += 1;
        // Prevent the compiler from collapsing the busy loop.
        asm volatile ("");
    }
    @atomicStore(u32, &t.done, 1, .release);
    while (true) {
        // SAFETY: finished worker parks; the timer keeps switching it out.
        asm volatile ("hlt");
    }
}
