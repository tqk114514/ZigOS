//! Repository-root entry for the host fuzz tool. Zig 0.17 only allows imports
//! inside a module's root directory, so the module is rooted here; the
//! implementation lives in tools/fuzz.zig.

pub const main = @import("tools/fuzz.zig").main;
