//! Repository-root entry for the host packer. Zig 0.17 only allows imports
//! inside a module's root directory, so the tool's module is rooted here; the
//! implementation lives in tools/mkinitramfs.zig and shares the image format
//! with src/fs/initramfs.zig.

pub const main = @import("tools/mkinitramfs.zig").main;
