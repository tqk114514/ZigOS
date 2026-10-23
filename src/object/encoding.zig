//! Handle encoding: u64 = generation << 32 | index. Pure functions.

pub fn pack(slot: u32, gen: u32) u64 {
    return (@as(u64, gen) << 32) | slot;
}

pub fn index(handle: u64) u32 {
    return @truncate(handle);
}

pub fn generation(handle: u64) u32 {
    return @truncate(handle >> 32);
}
