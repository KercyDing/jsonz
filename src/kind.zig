//! Type classification helpers for the JSON codec.

const std = @import("std");

const split_fields = !@hasField(std.builtin.Type.Struct, "fields");

pub const StructField = struct {
    name: [:0]const u8,
    type: type,
    default_value_ptr: ?*const anyopaque,

    pub fn defaultValue(comptime field: StructField) ?field.type {
        const value: *const field.type = @ptrCast(@alignCast(field.default_value_ptr orelse return null));
        return value.*;
    }
};

pub const EnumField = struct {
    name: [:0]const u8,
    value: comptime_int,
};

pub const UnionField = struct {
    name: [:0]const u8,
    type: type,
};

pub fn structFields(comptime T: type) []const if (split_fields) StructField else std.builtin.Type.StructField {
    const info = @typeInfo(T).@"struct";
    comptime if (!split_fields) return info.fields;

    comptime var fields: []const StructField = &.{};
    inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
        fields = fields ++ &[_]StructField{.{
            .name = name,
            .type = Field,
            .default_value_ptr = attrs.default_value_ptr,
        }};
    }
    return fields;
}

pub fn enumFields(comptime T: type) []const if (split_fields) EnumField else std.builtin.Type.EnumField {
    const info = @typeInfo(T).@"enum";
    comptime if (!split_fields) return info.fields;

    comptime var fields: []const EnumField = &.{};
    inline for (info.field_names, info.field_values) |name, value| {
        fields = fields ++ &[_]EnumField{.{ .name = name, .value = value }};
    }
    return fields;
}

pub fn unionFields(comptime T: type) []const if (split_fields) UnionField else std.builtin.Type.UnionField {
    const info = @typeInfo(T).@"union";
    comptime if (!split_fields) return info.fields;

    comptime var fields: []const UnionField = &.{};
    inline for (info.field_names, info.field_types) |name, Field| {
        fields = fields ++ &[_]UnionField{.{ .name = name, .type = Field }};
    }
    return fields;
}

/// Structural kind of a Zig type in the JSON data model.
pub const Kind = enum {
    bool,
    int,
    float,

    /// `[]u8`, `[]const u8`, and sentinel-terminated byte strings.
    string,

    array,

    /// `[]T`, except byte slices which are classified as `.string`.
    slice,

    optional,
    @"struct",
    tuple,
    @"union",
    @"enum",

    void,
};

/// Classify a Zig type into the JSON codec's structural type model.
pub fn typeKind(comptime T: type) Kind {
    return switch (@typeInfo(T)) {
        .bool => .bool,

        .int,
        .comptime_int,
        => .int,

        .float,
        .comptime_float,
        => .float,

        .void => .void,

        .optional => .optional,

        .@"enum" => .@"enum",
        .@"union" => .@"union",

        .pointer => |p| classifyPointer(T, p),

        .array => .array,

        .@"struct" => |s| if (s.is_tuple)
            .tuple
        else
            .@"struct",

        .null => @compileError(
            "The null type is not directly supported. " ++
                "Use an optional type such as ?T to represent JSON null.",
        ),

        else => @compileError(
            "Unsupported type for JSON codec: " ++ @typeName(T),
        ),
    };
}

fn classifyPointer(
    comptime T: type,
    comptime p: std.builtin.Type.Pointer,
) Kind {
    switch (p.size) {
        .slice => {
            if (p.child == u8)
                return .string;

            return .slice;
        },

        .many => {
            if (p.child == u8 and p.sentinel() != null)
                return .string;

            @compileError(
                "Unsupported many-pointer type for JSON codec: " ++
                    @typeName(T),
            );
        },

        .one => {
            @compileError(
                "Single-item pointers are not supported by the JSON codec: " ++
                    @typeName(T) ++
                    ". Deserialize the pointed-to value directly instead.",
            );
        },

        .c => {
            @compileError(
                "C pointers are not supported by the JSON codec: " ++
                    @typeName(T),
            );
        },
    }
}

/// Returns whether `T` provides a custom serialization hook.
pub fn hasCustomSerialize(comptime T: type) bool {
    return hasDeclSafe(T, "jsonzSerialize");
}

/// Returns whether `T` provides a custom deserialization hook.
pub fn hasCustomDeserialize(comptime T: type) bool {
    return hasDeclSafe(T, "jsonzDeserialize");
}

fn hasDeclSafe(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct",
        .@"union",
        .@"enum",
        .@"opaque",
        => @hasDecl(T, name),

        else => false,
    };
}

/// Extract the child type from an optional, pointer, slice, or array.
pub fn Child(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .optional => |o| o.child,

        .pointer => |p| switch (p.size) {
            .one,
            .slice,
            .many,
            .c,
            => p.child,
        },

        .array => |a| a.child,

        else => @compileError(
            "Cannot get child type of " ++ @typeName(T),
        ),
    };
}

/// Returns whether `T` is represented as a JSON string.
pub fn isString(comptime T: type) bool {
    return typeKind(T) == .string;
}

/// Returns whether a string type can borrow directly from the JSON input.
pub fn canBorrowString(comptime T: type) bool {
    const info = @typeInfo(T);

    if (info != .pointer)
        return false;

    const p = info.pointer;

    if (p.child != u8)
        return false;

    return switch (p.size) {
        .slice => p.sentinel() == null,
        .many => false,
        .one, .c => false,
    };
}

/// Returns whether deserializing `T` requires sentinel-terminated storage.
pub fn requiresStringSentinel(comptime T: type) bool {
    const info = @typeInfo(T);

    if (info != .pointer)
        return false;

    const p = info.pointer;

    if (p.child != u8)
        return false;

    return switch (p.size) {
        .slice, .many => p.sentinel() != null,
        .one, .c => false,
    };
}

/// Returns whether `T` may require runtime-sized storage during deserialization.
pub fn isDynamic(comptime T: type) bool {
    return switch (typeKind(T)) {
        .bool,
        .int,
        .float,
        .@"enum",
        .void,
        => false,

        .string,
        .slice,
        => true,

        .array => isDynamic(Child(T)),

        .optional => isDynamic(Child(T)),

        .tuple,
        .@"struct",
        => structIsDynamic(T),

        .@"union" => unionIsDynamic(T),
    };
}

fn structIsDynamic(comptime T: type) bool {
    inline for (comptime structFields(T)) |field| {
        if (isDynamic(field.type))
            return true;
    }

    return false;
}

fn unionIsDynamic(comptime T: type) bool {
    inline for (comptime unionFields(T)) |field| {
        if (isDynamic(field.type))
            return true;
    }

    return false;
}

const testing = std.testing;

test "scalar kinds" {
    try testing.expectEqual(.bool, comptime typeKind(bool));

    try testing.expectEqual(.int, comptime typeKind(u8));
    try testing.expectEqual(.int, comptime typeKind(i64));
    try testing.expectEqual(.int, comptime typeKind(u128));

    try testing.expectEqual(.float, comptime typeKind(f32));
    try testing.expectEqual(.float, comptime typeKind(f64));

    try testing.expectEqual(.void, comptime typeKind(void));
}

test "string kinds" {
    try testing.expectEqual(
        .string,
        comptime typeKind([]const u8),
    );

    try testing.expectEqual(
        .string,
        comptime typeKind([]u8),
    );

    try testing.expectEqual(
        .string,
        comptime typeKind([:0]const u8),
    );

    try testing.expectEqual(
        .string,
        comptime typeKind([*:0]const u8),
    );
}

test "container kinds" {
    try testing.expectEqual(
        .array,
        comptime typeKind([4]u8),
    );

    try testing.expectEqual(
        .array,
        comptime typeKind([3]i32),
    );

    try testing.expectEqual(
        .slice,
        comptime typeKind([]const i32),
    );

    try testing.expectEqual(
        .optional,
        comptime typeKind(?u32),
    );
}

test "struct and tuple kinds" {
    const Point = struct {
        x: i32,
        y: i32,
    };

    try testing.expectEqual(
        .@"struct",
        comptime typeKind(Point),
    );

    try testing.expectEqual(
        .tuple,
        comptime typeKind(struct { i32, i32 }),
    );
}

test "enum and union kinds" {
    const Color = enum {
        red,
        green,
        blue,
    };

    const Shape = union(enum) {
        circle: f64,
        rect: struct {
            w: f64,
            h: f64,
        },
    };

    try testing.expectEqual(
        .@"enum",
        comptime typeKind(Color),
    );

    try testing.expectEqual(
        .@"union",
        comptime typeKind(Shape),
    );
}

test "custom hooks" {
    const SerializeOnly = struct {
        value: u32,

        pub fn jsonzSerialize(
            _: @This(),
            _: anytype,
        ) !void {}
    };

    const DeserializeOnly = struct {
        value: u32,

        pub fn jsonzDeserialize(
            _: anytype,
        ) !@This() {
            return .{ .value = 0 };
        }
    };

    try testing.expectEqual(
        .@"struct",
        comptime typeKind(SerializeOnly),
    );

    try testing.expectEqual(
        .@"struct",
        comptime typeKind(DeserializeOnly),
    );

    try testing.expect(
        comptime hasCustomSerialize(SerializeOnly),
    );

    try testing.expect(
        !comptime hasCustomDeserialize(SerializeOnly),
    );

    try testing.expect(
        !comptime hasCustomSerialize(DeserializeOnly),
    );

    try testing.expect(
        comptime hasCustomDeserialize(DeserializeOnly),
    );
}

test "child type" {
    try testing.expect(
        Child(?u32) == u32,
    );

    try testing.expect(
        Child(*u32) == u32,
    );

    try testing.expect(
        Child([]const u8) == u8,
    );

    try testing.expect(
        Child([4]i32) == i32,
    );
}

test "borrowable strings" {
    try testing.expect(
        comptime canBorrowString([]const u8),
    );

    try testing.expect(
        comptime canBorrowString([]u8),
    );

    try testing.expect(
        !comptime canBorrowString([:0]const u8),
    );

    try testing.expect(
        !comptime canBorrowString([*:0]const u8),
    );
}

test "sentinel strings" {
    try testing.expect(
        !comptime requiresStringSentinel([]const u8),
    );

    try testing.expect(
        comptime requiresStringSentinel([:0]const u8),
    );

    try testing.expect(
        comptime requiresStringSentinel([*:0]const u8),
    );
}

test "dynamic types" {
    const Static = struct {
        id: u64,
        enabled: bool,
        position: [3]f32,
    };

    const Dynamic = struct {
        id: u64,
        name: []const u8,
        values: []u32,
    };

    try testing.expect(
        !comptime isDynamic(u64),
    );

    try testing.expect(
        !comptime isDynamic([4]u32),
    );

    try testing.expect(
        comptime isDynamic([]u32),
    );

    try testing.expect(
        comptime isDynamic([]const u8),
    );

    try testing.expect(
        !comptime isDynamic(Static),
    );

    try testing.expect(
        comptime isDynamic(Dynamic),
    );
}
