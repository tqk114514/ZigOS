//! Enforces the kernel's module dependency DAG and import rules.
//!
//! Rules:
//!   - Cross-module imports must resolve to `<module>/interface.zig`.
//!   - A module may only import modules below it in the DAG.
//!   - `@import` arguments must be plain single-line string literals.
//!   - External packages are forbidden; only `std` and `builtin` are allowed.
//!   - Userspace-only std namespaces are banned from kernel code.
//!
//! The tool only reads files; it never writes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Module = enum {
    lib,
    hal,
    arch,
    mm,
    object,
    sched,
    fs,
    net,
    drivers,
    kernel,

    /// Dependency direction. `kernel` is the composition root and may import
    /// every module; every other edge points towards a lower layer.
    fn mayImport(self: Module, target: Module) bool {
        if (self == target) return true;
        return switch (self) {
            .lib => false,
            .hal => target == .lib,
            .arch => target == .lib or target == .hal,
            .mm => target == .lib or target == .hal or target == .arch,
            .object => target == .lib or target == .hal or target == .arch or target == .mm,
            .sched => target == .lib or
                target == .hal or
                target == .arch or
                target == .mm or
                target == .object,
            .fs, .net, .drivers => target == .lib or
                target == .hal or
                target == .arch or
                target == .mm or
                target == .object or
                target == .sched,
            .kernel => true,
        };
    }
};

const banned_std = [_][]const u8{
    "std.Io",
    "std.fs",
    "std.process",
    "std.Thread",
    "std.heap",
    "std.os",
    "std.posix",
    "std.net",
    "std.debug",
    "std.log",
    "std.time",
};

const Diagnostic = struct {
    path: []const u8,
    line: usize,
    message: []const u8,
};

const Diagnostics = struct {
    arena: Allocator,
    items: std.ArrayList(Diagnostic) = .empty,

    fn add(
        self: *Diagnostics,
        path: []const u8,
        line: usize,
        comptime fmt: []const u8,
        args: anytype,
    ) !void {
        const message = try std.fmt.allocPrint(self.arena, fmt, args);
        try self.items.append(self.arena, .{ .path = path, .line = line, .message = message });
    }
};

const Import = struct {
    path: []const u8,
    line: usize,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    const root = if (args.len > 1) args[1] else "src";

    var dir = Io.Dir.cwd().openDir(init.io, root, .{ .iterate = true }) catch |err| {
        std.debug.print("check-deps: cannot open '{s}': {s}\n", .{ root, @errorName(err) });
        std.process.exit(2);
    };
    defer dir.close(init.io);

    var walker = dir.walk(arena) catch |err| {
        std.debug.print("check-deps: cannot walk '{s}': {s}\n", .{ root, @errorName(err) });
        std.process.exit(2);
    };
    defer walker.deinit();

    var diags = Diagnostics{ .arena = arena };
    var file_count: usize = 0;
    var import_count: usize = 0;

    while (true) {
        const maybe_entry = walker.next(init.io) catch |err| {
            std.debug.print("check-deps: walk '{s}': {s}\n", .{ root, @errorName(err) });
            std.process.exit(2);
        };
        const entry = maybe_entry orelse break;
        if (entry.kind != .file) continue;

        const rel = try normalizeSlashes(arena, entry.path);
        if (!std.mem.endsWith(u8, rel, ".zig")) continue;

        file_count += 1;
        const source = dir.readFileAlloc(init.io, entry.path, arena, .limited(8 << 20)) catch |err| {
            std.debug.print("check-deps: read '{s}': {s}\n", .{ entry.path, @errorName(err) });
            std.process.exit(2);
        };
        import_count += try analyzeFile(arena, rel, source, &diags);
    }

    if (diags.items.items.len == 0) {
        std.debug.print("check-deps: {d} files, {d} imports, DAG OK\n", .{ file_count, import_count });
        return;
    }

    for (diags.items.items) |diag| {
        std.debug.print("{s}/{s}:{d}: error: {s}\n", .{ root, diag.path, diag.line, diag.message });
    }
    std.debug.print("check-deps: {d} violation(s)\n", .{diags.items.items.len});
    std.process.exit(1);
}

fn analyzeFile(
    arena: Allocator,
    rel_path: []const u8,
    source: []const u8,
    diags: *Diagnostics,
) !usize {
    const source_module = moduleFromPath(rel_path) catch |err| {
        try diags.add(rel_path, 1, "cannot classify file: {s}", .{@errorName(err)});
        return 0;
    };

    const masked = try maskNonCode(arena, source);
    var imports: std.ArrayList(Import) = .empty;
    defer imports.deinit(arena);
    try collectImports(arena, rel_path, source, masked, &imports, diags);

    for (imports.items) |import| {
        if (std.mem.eql(u8, import.path, "std") or std.mem.eql(u8, import.path, "builtin")) continue;

        if (!std.mem.endsWith(u8, import.path, ".zig")) {
            try diags.add(
                rel_path,
                import.line,
                "external package import '{s}' is not allowed",
                .{import.path},
            );
            continue;
        }

        const target = normalizeRel(arena, rel_path, import.path) catch |err| {
            try diags.add(
                rel_path,
                import.line,
                "invalid import '{s}': {s}",
                .{ import.path, @errorName(err) },
            );
            continue;
        };

        const target_module = moduleFromPath(target) catch |err| {
            try diags.add(
                rel_path,
                import.line,
                "import '{s}' resolves to unclassified file '{s}': {s}",
                .{ import.path, target, @errorName(err) },
            );
            continue;
        };

        if (target_module == source_module) continue;

        if (!source_module.mayImport(target_module)) {
            try diags.add(
                rel_path,
                import.line,
                "{s} may not import {s} (target '{s}')",
                .{ @tagName(source_module), @tagName(target_module), target },
            );
            continue;
        }

        const expected = try std.fmt.allocPrint(arena, "{s}/interface.zig", .{@tagName(target_module)});
        if (!std.mem.eql(u8, target, expected)) {
            try diags.add(
                rel_path,
                import.line,
                "cross-module import must target '{s}', not '{s}'",
                .{ expected, target },
            );
        }
    }

    try checkBannedStd(rel_path, source, masked, diags);
    return imports.items.len;
}

fn collectImports(
    arena: Allocator,
    rel_path: []const u8,
    source: []const u8,
    masked: []const u8,
    imports: *std.ArrayList(Import),
    diags: *Diagnostics,
) !void {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, masked, search, "@import")) |pos| {
        search = pos + "@import".len;
        if (pos > 0 and isIdentChar(masked[pos - 1])) continue;

        var cursor = pos + "@import".len;
        while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor >= source.len or source[cursor] != '(') {
            try diags.add(rel_path, lineOf(source, pos), "@import must be followed by '(...)'", .{});
            continue;
        }

        cursor += 1;
        while (cursor < source.len and std.ascii.isWhitespace(source[cursor])) : (cursor += 1) {}
        if (cursor >= source.len or source[cursor] != '"') {
            try diags.add(rel_path, lineOf(source, pos), "import path must be a string literal", .{});
            continue;
        }

        const start = cursor + 1;
        var end = start;
        var bad = false;
        while (end < source.len) : (end += 1) {
            const c = source[end];
            if (c == '\\' or c == '\n' or c == '\r') {
                bad = true;
                break;
            }
            if (c == '"') break;
        }
        if (bad or end >= source.len or source[end] != '"') {
            try diags.add(
                rel_path,
                lineOf(source, pos),
                "import path must be a plain single-line string literal",
                .{},
            );
            continue;
        }

        try imports.append(arena, .{
            .path = source[start..end],
            .line = lineOf(source, pos),
        });
        search = end + 1;
    }
}

fn checkBannedStd(
    rel_path: []const u8,
    source: []const u8,
    masked: []const u8,
    diags: *Diagnostics,
) !void {
    for (banned_std) |token| {
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, masked, search, token)) |pos| {
            search = pos + token.len;
            if (pos > 0 and isIdentChar(masked[pos - 1])) continue;
            if (search < masked.len and isIdentChar(masked[search])) continue;
            try diags.add(rel_path, lineOf(source, pos), "banned std namespace '{s}'", .{token});
        }
    }
}

/// Replaces comments, string contents and multiline string lines with spaces,
/// preserving byte offsets and newlines so diagnostics keep their line numbers.
fn maskNonCode(allocator: Allocator, source: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, source.len);
    @memset(out, ' ');

    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        switch (c) {
            '\n', '\r' => {
                out[i] = c;
                i += 1;
            },
            ' ', '\t' => {
                out[i] = c;
                i += 1;
            },
            '/' => {
                if (i + 1 < source.len and source[i + 1] == '/') {
                    while (i < source.len and source[i] != '\n') : (i += 1) out[i] = ' ';
                } else {
                    out[i] = c;
                    i += 1;
                }
            },
            '"' => {
                out[i] = ' ';
                i += 1;
                while (i < source.len) {
                    const d = source[i];
                    if (d == '\\' and i + 1 < source.len) {
                        out[i] = ' ';
                        out[i + 1] = ' ';
                        i += 2;
                    } else if (d == '"') {
                        out[i] = ' ';
                        i += 1;
                        break;
                    } else {
                        out[i] = if (d == '\n' or d == '\r') d else ' ';
                        i += 1;
                    }
                }
            },
            '\\' => {
                if (i + 1 < source.len and source[i + 1] == '\\') {
                    while (i < source.len and source[i] != '\n') : (i += 1) out[i] = ' ';
                } else {
                    out[i] = c;
                    i += 1;
                }
            },
            else => {
                out[i] = c;
                i += 1;
            },
        }
    }
    return out;
}

fn moduleFromPath(path: []const u8) !Module {
    if (std.mem.eql(u8, path, "main.zig")) return .kernel;
    const slash = std.mem.indexOfScalar(u8, path, '/') orelse return error.UnclassifiedFile;
    const name = path[0..slash];
    return std.meta.stringToEnum(Module, name) orelse error.UnknownModule;
}

/// Resolves an import relative to the importing file, producing a path relative
/// to `src/`. Imports may not escape `src/` or use platform-specific separators.
fn normalizeRel(allocator: Allocator, from_path: []const u8, import_path: []const u8) ![]u8 {
    if (import_path.len == 0) return error.EmptyImport;
    if (std.mem.indexOfAny(u8, import_path, "\\:") != null) return error.InvalidImportPath;
    if (import_path[0] == '/') return error.AbsoluteImport;
    if (!std.mem.endsWith(u8, import_path, ".zig")) return error.NotZigFile;

    var parts: std.ArrayList([]const u8) = .empty;
    defer parts.deinit(allocator);

    if (std.mem.lastIndexOfScalar(u8, from_path, '/')) |i| {
        var dirs = std.mem.splitScalar(u8, from_path[0..i], '/');
        while (dirs.next()) |part| {
            if (part.len != 0) try parts.append(allocator, part);
        }
    }

    var segments = std.mem.splitScalar(u8, import_path, '/');
    while (segments.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        if (std.mem.eql(u8, part, "..")) {
            if (parts.items.len == 0) return error.EscapesRoot;
            _ = parts.pop();
        } else {
            try parts.append(allocator, part);
        }
    }

    if (parts.items.len == 0) return error.EmptyImport;
    return std.mem.join(allocator, "/", parts.items);
}

fn normalizeSlashes(allocator: Allocator, path: []const u8) ![]u8 {
    const out = try allocator.dupe(u8, path);
    for (out) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return out;
}

fn lineOf(source: []const u8, pos: usize) usize {
    var line: usize = 1;
    for (source[0..@min(pos, source.len)]) |c| {
        if (c == '\n') line += 1;
    }
    return line;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn expectClean(arena: Allocator, rel_path: []const u8, source: []const u8) !void {
    var diags = Diagnostics{ .arena = arena };
    _ = try analyzeFile(arena, rel_path, source, &diags);
    try std.testing.expectEqual(@as(usize, 0), diags.items.items.len);
}

fn expectViolation(
    arena: Allocator,
    rel_path: []const u8,
    source: []const u8,
    needle: []const u8,
) !void {
    var diags = Diagnostics{ .arena = arena };
    _ = try analyzeFile(arena, rel_path, source, &diags);
    try std.testing.expect(diags.items.items.len > 0);
    for (diags.items.items) |diag| {
        if (std.mem.indexOf(u8, diag.message, needle) != null) return;
    }
    std.debug.print("expected a diagnostic containing '{s}', got:\n", .{needle});
    for (diags.items.items) |diag| {
        std.debug.print("  {s}:{d}: {s}\n", .{ diag.path, diag.line, diag.message });
    }
    return error.ExpectedDiagnosticMissing;
}

test "module classification" {
    try std.testing.expectEqual(Module.kernel, try moduleFromPath("main.zig"));
    try std.testing.expectEqual(Module.mm, try moduleFromPath("mm/page.zig"));
    try std.testing.expectEqual(Module.drivers, try moduleFromPath("drivers/virtio_blk.zig"));
    try std.testing.expectError(error.UnclassifiedFile, moduleFromPath("stray.zig"));
    try std.testing.expectError(error.UnknownModule, moduleFromPath("nope/x.zig"));
}

test "relative import normalization" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try std.testing.expectEqualStrings(
        "arch/interface.zig",
        try normalizeRel(arena, "mm/page.zig", "../arch/interface.zig"),
    );
    try std.testing.expectEqualStrings(
        "mm/interface.zig",
        try normalizeRel(arena, "main.zig", "mm/interface.zig"),
    );
    try std.testing.expectError(
        error.EscapesRoot,
        normalizeRel(arena, "mm/page.zig", "../../x.zig"),
    );
    try std.testing.expectError(
        error.InvalidImportPath,
        normalizeRel(arena, "mm/page.zig", "..\\arch\\x.zig"),
    );
    try std.testing.expectError(
        error.NotZigFile,
        normalizeRel(arena, "mm/page.zig", "../arch/x"),
    );
}

test "mm may import the arch interface" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectClean(arena, "mm/page.zig", "const arch = @import(\"../arch/interface.zig\");");
    try expectClean(arena, "mm/page.zig", "const std = @import(\"std\");\nconst builtin = @import(\"builtin\");");
    try expectClean(arena, "mm/page.zig", "const alloc = @import(\"alloc.zig\");");
}

test "arch may not import mm" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectViolation(
        arena,
        "arch/cpu.zig",
        "const mm = @import(\"../mm/interface.zig\");",
        "may not import mm",
    );
}

test "cross-module imports must target interface.zig" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectViolation(
        arena,
        "main.zig",
        "const page = @import(\"mm/page.zig\");",
        "must target 'mm/interface.zig'",
    );
}

test "imports inside comments and strings are ignored" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source =
        \\// @import("sched/interface.zig");
        \\const s = "@import(\"sched/interface.zig\")";
        \\const t =
        \\    \\ @import("net/interface.zig");
    ;
    try expectClean(arena, "mm/page.zig", source);
}

test "non-literal and external imports are rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectViolation(
        arena,
        "mm/page.zig",
        "const x = @import(module_name);",
        "string literal",
    );
    try expectViolation(
        arena,
        "mm/page.zig",
        "const x = @import(\"somepkg\");",
        "external package import",
    );
    try expectViolation(
        arena,
        "mm/page.zig",
        "const x = @import(\"../../x.zig\");",
        "EscapesRoot",
    );
}

test "banned std namespaces are rejected outside strings and comments" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectViolation(arena, "mm/page.zig", "const Io = std.Io;", "std.Io");
    try expectClean(arena, "mm/page.zig", "// std.Io is userspace-only\nconst x = 1;");
    try expectClean(arena, "mm/page.zig", "const s = \"std.Io\";");
}

test "fs and drivers may block through sched" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectClean(
        arena,
        "fs/initramfs.zig",
        "const sched = @import(\"../sched/interface.zig\");",
    );
    try expectClean(
        arena,
        "drivers/virtio_blk.zig",
        "const sched = @import(\"../sched/interface.zig\");",
    );
    try expectViolation(
        arena,
        "sched/runqueue.zig",
        "const fs = @import(\"../fs/interface.zig\");",
        "may not import fs",
    );
}

test "files outside a known module are rejected" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectViolation(arena, "stray.zig", "// nothing", "cannot classify");
}
