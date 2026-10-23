//! Cross-CPU TLB shootdown over IPI vector 51. A global generation serializes
//! requests; every target reloads CR3 (flushing non-global entries) and
//! publishes the generation it has seen.

const apic = @import("apic.zig");
const cpu = @import("cpu.zig");
const exceptions = @import("exceptions.zig");
const percpu = @import("percpu.zig");
const format = @import("../lib/interface.zig").format;
const serial = @import("serial.zig");
const spinlock = @import("spinlock.zig");

const generation_timeout_ticks: u64 = 2_000_000_000;

var lock: spinlock.Lock align(64) = .{};
var generation: u64 = 0; // atomic publish, mutated under lock
var seen: [percpu.max_cpus]u64 = zeroSeen();

fn zeroSeen() [percpu.max_cpus]u64 {
    var out: [percpu.max_cpus]u64 = undefined;
    for (&out) |*slot| slot.* = 0;
    return out;
}

/// Registers the IPI handler; call once after the IDT exists.
pub fn init() void {
    exceptions.setVectorHandler(@intCast(exceptions.tlb_vector), handleIpi);
}

/// Flushes every other online CPU's TLB and waits for their acknowledgements.
pub fn shootdown() bool {
    const irq = lock.acquire();
    const next = @atomicLoad(u64, &generation, .monotonic) + 1;
    @atomicStore(u64, &generation, next, .release);
    const self = percpu.current().index;
    const count = percpu.count();
    // The initiator's own entries were flushed locally; record it as acked.
    seen[self] = next;

    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (index == self) continue;
        apic.sendIpi(percpu.at(index).apic_id, @intCast(exceptions.tlb_vector));
    }

    const deadline = cpu.rdtsc() + generation_timeout_ticks;
    while (true) {
        var pending = false;
        index = 0;
        while (index < count) : (index += 1) {
            if (@atomicLoad(u64, &seen[index], .acquire) != next) {
                pending = true;
                break;
            }
        }
        if (!pending) break;
        if (cpu.rdtsc() > deadline) {
            lock.release(irq);
            return false;
        }
        cpu.pause();
    }
    lock.release(irq);
    return true;
}

/// Smoke helper: performs one shootdown and reports how many CPUs acked.
pub fn probe() bool {
    const irq = lock.acquire();
    const next = @atomicLoad(u64, &generation, .monotonic) + 1;
    @atomicStore(u64, &generation, next, .release);
    seen[percpu.current().index] = next;
    const self = percpu.current().index;
    const count = percpu.count();
    var index: usize = 0;
    while (index < count) : (index += 1) {
        if (index == self) continue;
        apic.sendIpi(percpu.at(index).apic_id, @intCast(exceptions.tlb_vector));
    }

    const deadline = cpu.rdtsc() + generation_timeout_ticks;
    var acked: usize = 0;
    while (true) {
        acked = 0;
        index = 0;
        while (index < count) : (index += 1) {
            if (@atomicLoad(u64, &seen[index], .acquire) == next) acked += 1;
        }
        if (acked == count) break;
        if (cpu.rdtsc() > deadline) break;
        cpu.pause();
    }
    lock.release(irq);
    if (acked == count) {
        const console = serial.console;
        console.write("TLB: shootdown ok ");
        format.writeDec(console, acked);
        console.write(" cpus\n");
        return true;
    }
    return false;
}

fn handleIpi() callconv(.c) void {
    apic.eoi();
    // Flush this CPU's non-global TLB entries.
    // SAFETY: reading and writing CR3 at CPL0, which flushes the TLB.
    asm volatile ("mov %%cr3, %%rax\n\tmov %%rax, %%cr3" ::: .{ .rax = true, .memory = true });
    const current = @atomicLoad(u64, &generation, .acquire);
    @atomicStore(u64, &seen[percpu.current().index], current, .release);
}
