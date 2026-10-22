//! Preemptive round-robin kernel threads on per-CPU run queues. Static thread
//! pool and stacks; no allocation anywhere. The kernel composition root
//! registers the timer/IPI vector handlers, the IRQ-exit preemption hook, and
//! apEntry for the APs before interrupts are enabled.

const arch = @import("../arch/interface.zig");
const format = @import("../lib/interface.zig").format;

const max_threads: usize = 24;
const stack_size: usize = 16 * 1024;
const idle_stack_size: usize = 4 * 1024;
const quantum_ticks: u32 = 1;
const worker_target: u64 = 200_000;
const workers_per_cpu: usize = 2;
const deadline_ticks: u64 = 4_000_000_000;

pub const Thread = struct {
    rsp: usize = 0,
    entry: ?*const fn () callconv(.c) void = null,
    id: usize = 0,
    cpu: usize = 0,
    counter: u64 = 0,
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
};

// Boot-once state: each CPU touches only its own queue (under its lock) plus
// the shared pool (under pool_lock). `ready` is the release/acquire handoff.
var threads: [max_threads]Thread = defaultArray(Thread, max_threads);
var stacks: [max_threads][stack_size]u8 align(16) = undefined;
var idles: [arch.cpu_limit]Thread = defaultArray(Thread, arch.cpu_limit);
var idle_stacks: [arch.cpu_limit][idle_stack_size]u8 align(16) = undefined;
var queues: [arch.cpu_limit]Queue = defaultArray(Queue, arch.cpu_limit);
var pool_lock: arch.Lock align(64) = .{};
var workers: [arch.cpu_limit * workers_per_cpu]?*Thread = nullArray(arch.cpu_limit * workers_per_cpu);
var worker_count: usize = 0;

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

pub fn onTimer() callconv(.c) void {
    arch.eoi();
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
    if (prev != q.idle) enqueue(q, prev);
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
    return true;
}

fn spawn(entry: *const fn () callconv(.c) void, cpu: usize) ?*Thread {
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
    pool_lock.release(pool_irq);

    t.id = (@intFromPtr(t) - @intFromPtr(&threads[0])) / @sizeOf(Thread);
    t.cpu = cpu;
    t.counter = 0;
    t.done = 0;
    prepareOn(t, @intFromPtr(&stacks[t.id]) + stack_size, entry);

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
    // The slot intentionally stays reserved: this increment has no reclamation.
    const cpu = arch.cpuIndex();
    const q = &queues[cpu];
    const irq = q.lock.acquire();
    const prev = q.current;
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
        // SAFETY: idle with interrupts enabled; timer/IPI wake it.
        asm volatile ("hlt");
    }
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
