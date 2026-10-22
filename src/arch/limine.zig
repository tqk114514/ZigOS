//! Limine requests: base revision 6, HHDM, and the physical memory map.

const base_magic: u64 = 0xf9562b2d5c95a6c8;
const base_magic2: u64 = 0x6a7b384944536bdc;
const requested_base_revision: u64 = 6;

const common_magic0: u64 = 0xc7b1dd30df4c8b88;
const common_magic1: u64 = 0x0a82e883a194f07b;

export var limine_requests_start: [4]u64 linksection(".limine_requests_start") = .{
    0xf6b8f4b39de7d1ae,
    0xfab91a6940fcb9cf,
    0x785c6ed015d3e316,
    0x181e920a7852b9d9,
};

export var limine_base_revision: [3]u64 linksection(".limine_requests") = .{
    base_magic,
    base_magic2,
    requested_base_revision,
};

pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

const HhdmRequest = extern struct {
    id: [4]u64 = .{
        common_magic0,
        common_magic1,
        0x48dcf1cb8ad2b852,
        0x63984e959a98244b,
    },
    revision: u64 = 0,
    response: ?*const HhdmResponse = null,
};

pub const MemmapEntry = extern struct {
    base: u64,
    length: u64,
    type: u64,
};

pub const MemmapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: ?[*]const *const MemmapEntry,
};

const MemmapRequest = extern struct {
    id: [4]u64 = .{
        common_magic0,
        common_magic1,
        0x67cf3d9d378a806f,
        0xe304acdfc50c3c62,
    },
    revision: u64 = 0,
    response: ?*const MemmapResponse = null,
};

export var limine_hhdm_request: HhdmRequest linksection(".limine_requests") = .{};
export var limine_memmap_request: MemmapRequest linksection(".limine_requests") = .{};

export var limine_requests_end: [2]u64 linksection(".limine_requests_end") = .{
    0xadc0e0531bb10d03,
    0x9572709f31764c62,
};

pub fn baseRevisionSupported() bool {
    return limine_base_revision[2] == 0;
}

pub fn loadedBaseRevision() u64 {
    return limine_base_revision[1];
}

pub fn hhdmOffset() ?u64 {
    const response = limine_hhdm_request.response orelse return null;
    return response.offset;
}

pub fn memmap() ?*const MemmapResponse {
    return limine_memmap_request.response;
}
