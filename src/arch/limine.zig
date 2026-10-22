//! Limine requests: base revision 6, HHDM, the physical memory map, RSDP, and
//! the SMP processor table.

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

pub const RsdpResponse = extern struct {
    revision: u64,
    address: ?*anyopaque,
};

const RsdpRequest = extern struct {
    id: [4]u64 = .{
        common_magic0,
        common_magic1,
        0xc5e77b6b397e7b43,
        0x27637845accdcf3c,
    },
    revision: u64 = 0,
    response: ?*const RsdpResponse = null,
};

export var limine_hhdm_request: HhdmRequest linksection(".limine_requests") = .{};
export var limine_memmap_request: MemmapRequest linksection(".limine_requests") = .{};
export var limine_rsdp_request: RsdpRequest linksection(".limine_requests") = .{};

pub const MpInfo = extern struct {
    processor_id: u32,
    lapic_id: u32,
    reserved: u64,
    goto_address: ?*const fn (*MpInfo) callconv(.c) void,
    extra_argument: u64,
};

pub const MpResponse = extern struct {
    revision: u64,
    flags: u32,
    bsp_lapic_id: u32,
    cpu_count: u64,
    cpus: ?[*]*MpInfo,
};

const MpRequest = extern struct {
    id: [4]u64 = .{
        common_magic0,
        common_magic1,
        0x95a67b819a1b857e,
        0xa0b61b723b6a73e0,
    },
    revision: u64 = 0,
    response: ?*const MpResponse = null,
    // LIMINE_MP_REQUEST_X86_64_X2APIC: keep x2APIC instead of falling back.
    flags: u64 = 1,
};

export var limine_mp_request: MpRequest linksection(".limine_requests") = .{};

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

pub fn rsdp() ?u64 {
    const response = limine_rsdp_request.response orelse return null;
    const address = response.address orelse return null;
    // At base revision >= 4 the RSDP address is HHDM-mapped, not physical.
    return @intFromPtr(address);
}

pub fn mp() ?*const MpResponse {
    return limine_mp_request.response;
}
