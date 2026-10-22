//! Limine base revision 6 request and request-scan markers.

const base_magic: u64 = 0xf9562b2d5c95a6c8;
const base_magic2: u64 = 0x6a7b384944536bdc;
const requested_base_revision: u64 = 6;

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
