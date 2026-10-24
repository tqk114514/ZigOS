//! ZigOS user-mode shell. Runs in ring3 on top of the read-only initramfs.
//! No std, no libc: syscalls go straight through `syscall`.

const sys_exit: u64 = 0;
const sys_write: u64 = 1;
const sys_open: u64 = 3;
const sys_read: u64 = 4;
const sys_close: u64 = 5;

const error_value: u64 = ~@as(u64, 0);

/// Startup ABI: the kernel enters at `_start` with %rsp pointing here and all
/// other registers zeroed.
const StartupInfo = extern struct {
    console: u64,
    reserved: u64,
};

comptime {
    if (@sizeOf(StartupInfo) != 16) @compileError("startup ABI size changed");
}

export fn _start() callconv(.naked) noreturn {
    asm volatile (
        \\movq (%rsp), %rdi
        \\call shellMain
        \\ud2
    );
}

export fn shellMain(console: u64) callconv(.c) noreturn {
    var line: [128]u8 = undefined;
    write(console, "ZigOS shell (M3)\n");
    while (true) {
        write(console, "shell> ");
        const len = readLine(console, &line);
        if (len == 0) continue;
        const command = line[0..len];
        if (eql(command, "help")) {
            write(console, "commands: help, cat <path>, sysfuzz, exit\n");
        } else if (eql(command, "exit")) {
            exit(0);
        } else if (eql(command, "sysfuzz")) {
            sysfuzz(console);
        } else if (startsWith(command, "cat ")) {
            cat(console, command[4..]);
        } else {
            write(console, "unknown command\n");
        }
    }
}

fn readLine(console: u64, line: []u8) usize {
    var len: usize = 0;
    var ch: [1]u8 = undefined;
    while (true) {
        const got = syscall3(sys_read, console, @intFromPtr(&ch), 1);
        if (got == error_value) exit(1);
        if (got != 1) continue; // no byte yet: retry
        const c = ch[0];
        if (c == '\r') continue;
        if (c == '\n') {
            write(console, "\n");
            return len;
        }
        if ((c == 0x7f or c == 0x08) and len > 0) {
            len -= 1;
            write(console, "\x08 \x08");
            continue;
        }
        if (c < 0x20 or c > 0x7e or len == line.len) continue;
        line[len] = c;
        len += 1;
        write(console, &ch);
    }
}

fn cat(console: u64, path: []const u8) void {
    if (path.len == 0) {
        write(console, "usage: cat <path>\n");
        return;
    }
    const handle = syscall3(sys_open, @intFromPtr(path.ptr), path.len, 0);
    if (handle == error_value) {
        write(console, "not found\n");
        return;
    }
    var buf: [128]u8 = undefined;
    while (true) {
        const n = syscall3(sys_read, handle, @intFromPtr(&buf), buf.len);
        if (n == error_value) {
            write(console, "read error\n");
            break;
        }
        if (n == 0) break;
        write(console, buf[0..@intCast(n)]);
    }
    _ = syscall1(sys_close, handle);
}

fn write(console: u64, bytes: []const u8) void {
    _ = syscall3(sys_write, console, @intFromPtr(bytes.ptr), bytes.len);
}

/// Deterministic syscall-argument fuzz: invalid handles, lengths, pointers,
/// and numbers must return errors instead of disturbing the kernel.
fn sysfuzz(console: u64) void {
    var path: [80]u8 = undefined;
    var state: u64 = 0x9e37_79b9_7f4a_7c15;
    var index: usize = 0;
    while (index < path.len) : (index += 1) path[index] = @truncate(next(&state));

    state = 0x0123_4567_89ab_cdef;
    index = 0;
    while (index < 4000) : (index += 1) {
        const number = next(&state) % 7;
        const handle = next(&state) % 66; // 0..65: console plus invalid slots
        const len = switch (next(&state) % 6) {
            0 => 0,
            1 => 1,
            2 => 4095,
            3 => 4096,
            4 => 4097,
            else => next(&state) & 0xffff,
        };
        const ptr = badPointer(next(&state));
        switch (number) {
            1 => {
                const target = if ((next(&state) & 1) == 0) 0 else handle;
                _ = syscall3(sys_write, target, ptr, len);
            },
            2 => _ = syscall1(2, 0), // yield
            3 => _ = syscall3(sys_open, @intFromPtr(&path), next(&state) % 81, 0),
            4 => _ = syscall3(sys_read, 1 + (handle % 64), ptr, len), // never the console
            5 => _ = syscall1(sys_close, handle),
            else => _ = syscall3(6 + next(&state) % 1000, next(&state), next(&state), next(&state)),
        }
    }

    var ok = true;
    ok = ok and syscall3(sys_write, 0, badPointer(0xdead), 4097) == error_value;
    ok = ok and syscall3(sys_open, @intFromPtr(&path), 0, 0) == error_value;
    ok = ok and syscall3(sys_open, @intFromPtr(&path), path.len + 1, 0) == error_value;
    ok = ok and syscall3(sys_read, 0, badPointer(0xbeef), 0) == error_value;
    ok = ok and syscall1(sys_close, 0) == error_value; // console has no manage right
    ok = ok and syscall3(9999, 0, 0, 0) == error_value;
    if (ok) write(console, "sysfuzz ok\n") else write(console, "sysfuzz fail\n");
}

fn next(state: *u64) u64 {
    state.* ^= state.* << 13;
    state.* ^= state.* >> 7;
    state.* ^= state.* << 17;
    return state.*;
}

fn badPointer(raw: u64) u64 {
    const choices = [_]u64{
        0,
        0xfff,
        0x3f_ffff,
        0x60_0000,
        0x1_0000_0000,
        0xffff_ffff_ffff_ffff,
    };
    return choices[@intCast(raw % choices.len)];
}

fn exit(status: u64) noreturn {
    _ = syscall1(sys_exit, status);
    while (true) {}
}

fn syscall1(number: u64, a: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [number] "{rax}" (number),
          [a] "{rdi}" (a),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn syscall3(number: u64, a: u64, b: u64, c: u64) u64 {
    return asm volatile ("syscall"
        : [ret] "={rax}" (-> u64),
        : [number] "{rax}" (number),
          [a] "{rdi}" (a),
          [b] "{rsi}" (b),
          [c] "{rdx}" (c),
        : .{ .rcx = true, .r11 = true, .memory = true });
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}

fn startsWith(a: []const u8, prefix: []const u8) bool {
    if (a.len < prefix.len) return false;
    for (prefix, 0..) |c, i| if (a[i] != c) return false;
    return true;
}
