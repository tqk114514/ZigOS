//! Kernel panic namespace. Replaces std.debug.FullPanic so no userspace I/O
//! or formatting machinery is pulled into the kernel.

const arch = @import("../arch/interface.zig");
const format = @import("../lib/interface.zig").format;

pub fn call(msg: []const u8, ra: ?usize) noreturn {
    @branchHint(.cold);
    arch.disableInterrupts();
    arch.initSerial();
    const console = arch.serial_console;

    console.write("\nPANIC: ");
    console.write(msg);
    console.write("\n");
    if (ra) |addr| {
        console.write("RA: ");
        format.writeHex(console, @intCast(addr), 16);
        console.write("\n");
    }
    arch.printBacktrace(console);
    arch.qemuExit(0x11);
    arch.halt();
}

pub fn sentinelMismatch(expected: anytype, found: @TypeOf(expected)) noreturn {
    @branchHint(.cold);
    _ = found;
    call("sentinel mismatch", @returnAddress());
}

pub fn unwrapError(err: anyerror) noreturn {
    @branchHint(.cold);
    _ = err;
    call("attempt to unwrap error", @returnAddress());
}

pub fn outOfBounds(index: usize, len: usize) noreturn {
    @branchHint(.cold);
    _ = index;
    _ = len;
    call("index out of bounds", @returnAddress());
}

pub fn startGreaterThanEnd(start: usize, end: usize) noreturn {
    @branchHint(.cold);
    _ = start;
    _ = end;
    call("start index is larger than end index", @returnAddress());
}

pub fn inactiveUnionField(active: anytype, accessed: @TypeOf(active)) noreturn {
    @branchHint(.cold);
    _ = accessed;
    call("access of inactive union field", @returnAddress());
}

pub fn sliceCastLenRemainder(src_len: usize) noreturn {
    @branchHint(.cold);
    _ = src_len;
    call("slice length does not divide exactly into destination elements", @returnAddress());
}

pub fn reachedUnreachable() noreturn {
    @branchHint(.cold);
    call("reached unreachable code", @returnAddress());
}

pub fn unwrapNull() noreturn {
    @branchHint(.cold);
    call("attempt to use null value", @returnAddress());
}

pub fn castToNull() noreturn {
    @branchHint(.cold);
    call("cast causes pointer to be null", @returnAddress());
}

pub fn incorrectAlignment() noreturn {
    @branchHint(.cold);
    call("incorrect alignment", @returnAddress());
}

pub fn invalidErrorCode() noreturn {
    @branchHint(.cold);
    call("invalid error code", @returnAddress());
}

pub fn unexpectedErrorCode(err: anyerror) noreturn {
    @branchHint(.cold);
    _ = err;
    call("unexpected error code", @returnAddress());
}

pub fn integerOutOfBounds() noreturn {
    @branchHint(.cold);
    call("integer does not fit in destination type", @returnAddress());
}

pub fn integerOverflow() noreturn {
    @branchHint(.cold);
    call("integer overflow", @returnAddress());
}

pub fn shlOverflow() noreturn {
    @branchHint(.cold);
    call("left shift overflowed bits", @returnAddress());
}

pub fn shrOverflow() noreturn {
    @branchHint(.cold);
    call("right shift overflowed bits", @returnAddress());
}

pub fn divideByZero() noreturn {
    @branchHint(.cold);
    call("division by zero", @returnAddress());
}

pub fn exactDivisionRemainder() noreturn {
    @branchHint(.cold);
    call("exact division produced remainder", @returnAddress());
}

pub fn integerPartOutOfBounds() noreturn {
    @branchHint(.cold);
    call("integer part of floating point value out of bounds", @returnAddress());
}

pub fn corruptSwitch() noreturn {
    @branchHint(.cold);
    call("switch on corrupt value", @returnAddress());
}

pub fn shiftRhsTooBig() noreturn {
    @branchHint(.cold);
    call("shift amount is greater than the type size", @returnAddress());
}

pub fn invalidEnumValue() noreturn {
    @branchHint(.cold);
    call("invalid enum value", @returnAddress());
}

pub fn forLenMismatch() noreturn {
    @branchHint(.cold);
    call("for loop over objects with non-equal lengths", @returnAddress());
}

pub fn copyLenMismatch() noreturn {
    @branchHint(.cold);
    call("source and destination have non-equal lengths", @returnAddress());
}

pub fn memcpyAlias() noreturn {
    @branchHint(.cold);
    call("@memcpy arguments alias", @returnAddress());
}

pub fn noreturnReturned() noreturn {
    @branchHint(.cold);
    call("'noreturn' function returned", @returnAddress());
}

pub fn loadUninstantiableType() noreturn {
    @branchHint(.cold);
    call("attempt to load uninstantiable type", @returnAddress());
}
