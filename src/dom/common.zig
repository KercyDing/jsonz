//! Vocabulary shared by the compact and mutable DOM models.
const std = @import("std");
const pool_mod = @import("pool.zig");

/// The JSON kind represented by a DOM node.
pub const Kind = enum {
    null,
    bool,
    number,
    string,
    array,
    object,
};

/// Options that control DOM serialization.
pub const WriteOptions = struct {
    /// Format objects and arrays with four-space indentation and line breaks.
    pretty: bool = false,
};

/// Errors returned when a node cannot be accessed or converted.
pub const AccessError = error{
    UnexpectedType,
    OutOfRange,
    MissingField,
    OutOfBounds,
};

/// Errors from resolving an RFC 6901 JSON Pointer.
pub const PointerError = AccessError || error{
    InvalidPointer,
    InvalidArrayIndex,
    PointerTooLong,
};

/// Numeric types accepted by `Node.toNumber` and `Node.asNumber`.
pub const NumberType = enum {
    i8,
    i16,
    i32,
    i64,
    i128,
    isize,
    u8,
    u16,
    u32,
    u64,
    u128,
    usize,
    f16,
    f32,
    f64,

    pub fn Type(comptime self: NumberType) type {
        return switch (self) {
            .i8 => i8,
            .i16 => i16,
            .i32 => i32,
            .i64 => i64,
            .i128 => i128,
            .isize => isize,
            .u8 => u8,
            .u16 => u16,
            .u32 => u32,
            .u64 => u64,
            .u128 => u128,
            .usize => usize,
            .f16 => f16,
            .f32 => f32,
            .f64 => f64,
        };
    }
};

/// The parsed storage behind every `Node`.
///
/// `input` is the (owned or caller-provided) JSON buffer whose escape
/// sequences were decoded in place; `nodes` is the node pool. Both slices are
/// borrowed from the owning `Document` and are only valid while it lives.
pub const Storage = struct {
    nodes: []const pool_mod.NodeData,
    input: []const u8,
};
