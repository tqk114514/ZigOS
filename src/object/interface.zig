//! Object and handle API for upper modules.

const object = @import("object.zig");

pub const Object = object.Object;
pub const HandleTable = object.HandleTable;
pub const Rights = object.Rights;
pub const capacity = object.capacity;

pub fn runSmoke() bool {
    return object.runSmoke();
}
