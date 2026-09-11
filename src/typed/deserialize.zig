const std = @import("std");
const kind = @import("kind.zig");
const cursor_mod = @import("cursor.zig");
const pool_mod = @import("pool.zig");
const serialize_mod = @import("serialize.zig");

const Allocator = std.mem.Allocator;
const Cursor = cursor_mod.Cursor;
const Token = cursor_mod.Token;

pub const Error = cursor_mod.Error || error{
    OutOfMemory,
    WrongType,
    UnknownField,
    MissingField,
    InvalidUnicode,
    TrailingData,
};

pub const Options = struct {
    /// Ignore JSON object fields that have no matching field in the target type.
    ignore_unknown_fields: bool = false,
    /// Reject input nested deeper than this many arrays or objects.
    max_depth: u32 = 256,
};

/// The owning result returned by `parse`.
///
/// `value` and all slices reachable from it remain valid until `deinit` is
/// called. The result owns its backing buffer and must be deinitialized once.
pub fn Parsed(comptime T: type) type {
    return struct {
        value: T,
        buffer: []u8,
        fallback_arena: std.heap.ArenaAllocator,
        backing_allocator: Allocator,

        /// Releases all allocations made while parsing and invalidates `value`.
        pub fn deinit(self: *@This()) void {
            self.fallback_arena.deinit();
            self.backing_allocator.free(self.buffer);
            self.* = undefined;
        }

        /// Serializes `value` to a new JSON byte slice owned by `allocator`.
        pub fn toSlice(
            self: *const @This(),
            allocator: Allocator,
            options: serialize_mod.Options,
        ) ![]u8 {
            return serialize_mod.toSlice(allocator, self.value, options);
        }

        /// Serializes `value` directly to `writer`.
        pub fn toWriter(
            self: *const @This(),
            writer: *std.Io.Writer,
            options: serialize_mod.Options,
        ) !void {
            return serialize_mod.toWriter(writer, self.value, options);
        }
    };
}

/// Low-level typed deserializer used by custom `jsonzDeserialize` hooks.
/// Most applications should call `parse`, `parseBorrowed`, or `parseInto`.
pub const Deserializer = struct {
    cursor: Cursor,
    allocator: Allocator,
    options: Options,
    borrow_strings: bool,

    /// Creates a deserializer that owns decoded strings through `allocator`.
    pub fn init(allocator: Allocator, input: []const u8, options: Options) Deserializer {
        return .{
            .cursor = .{ .input = input, .max_depth = options.max_depth },
            .allocator = allocator,
            .options = options,
            .borrow_strings = false,
        };
    }

    /// Creates a deserializer that borrows unescaped strings from `input`.
    /// Strings containing JSON escapes are decoded into memory from `allocator`.
    pub fn initBorrowed(allocator: Allocator, input: []const u8, options: Options) Deserializer {
        var deserializer = init(allocator, input, options);
        deserializer.borrow_strings = true;
        return deserializer;
    }

    /// Deserializes the next JSON value as `T`.
    pub fn deserialize(self: *Deserializer, comptime T: type) Error!T {
        return deserializeValue(T, self);
    }

    /// Deserializes the next value as a JSON boolean.
    pub fn deserializeBool(self: *Deserializer) Error!bool {
        return switch (try self.cursor.next()) {
            .true_lit => true,
            .false_lit => false,
            else => error.WrongType,
        };
    }

    /// Deserializes the next JSON number as integer type `T`.
    pub fn deserializeInt(self: *Deserializer, comptime T: type) Error!T {
        if (comptime @typeInfo(T).int.bits <= 64) return self.cursor.readInt(T);
        return switch (try self.cursor.next()) {
            .number => |raw| std.fmt.parseInt(T, raw, 10) catch error.InvalidNumber,
            else => error.WrongType,
        };
    }

    /// Deserializes the next JSON number as floating-point type `T`.
    pub fn deserializeFloat(self: *Deserializer, comptime T: type) Error!T {
        return self.cursor.readFloat(T) catch |err| switch (err) {
            error.UnexpectedToken => error.WrongType,
            else => |other| other,
        };
    }

    /// Deserializes the next JSON string, borrowing or allocating according to this deserializer.
    pub fn deserializeString(self: *Deserializer) Error![]const u8 {
        const raw = switch (try self.cursor.next()) {
            .string => |value| value,
            else => return error.WrongType,
        };

        return self.materializeString(raw);
    }

    /// Converts a raw string token to decoded UTF-8, borrowing it when possible.
    /// `raw` must be the most recent string token returned by this deserializer's cursor.
    pub fn materializeString(self: *Deserializer, raw: []const u8) Error![]const u8 {
        if (!self.cursor.last_string_has_escape) {
            if (self.borrow_strings) return raw;
            return self.allocator.dupe(u8, raw) catch error.OutOfMemory;
        }
        return unescapeString(self.allocator, raw);
    }
};

fn parseAllocating(comptime T: type, allocator: Allocator, input: []const u8, options: Options) Error!T {
    var deserializer = Deserializer.init(allocator, input, options);
    const value = try deserializer.deserialize(T);
    deserializer.cursor.finish() catch return error.TrailingData;
    return value;
}

/// Parses JSON while borrowing unescaped strings from `input`.
///
/// The returned value borrows `input`; escaped strings and container metadata
/// may use `allocator`. Keep both alive for as long as the returned value is used.
pub fn parseBorrowed(comptime T: type, allocator: Allocator, input: []const u8, options: Options) Error!T {
    var deserializer = Deserializer.initBorrowed(allocator, input, options);
    const value = try deserializer.deserialize(T);
    deserializer.cursor.finish() catch return error.TrailingData;
    return value;
}

/// Parses JSON using `buffer` for allocations.
///
/// The returned value borrows `buffer`, so callers must keep it alive. Returns
/// `error.OutOfMemory` when the buffer cannot hold the parsed representation.
pub fn parseInto(comptime T: type, buffer: []u8, input: []const u8, options: Options) Error!T {
    var fixed_buffer = std.heap.FixedBufferAllocator.init(buffer);
    return parseAllocating(T, fixed_buffer.allocator(), input, options);
}

/// Parses JSON into an owning `Parsed(T)` result.
///
/// This is the convenient default for typed parsing: call `deinit` on the
/// returned value when finished.
pub fn parse(comptime T: type, allocator: Allocator, input: []const u8, options: Options) Error!Parsed(T) {
    const pool_size = std.math.mul(usize, input.len, 4) catch return error.OutOfMemory;
    const buffer = allocator.alloc(u8, @max(pool_size, 256)) catch return error.OutOfMemory;
    errdefer allocator.free(buffer);

    var fallback = std.heap.ArenaAllocator.init(allocator);
    errdefer fallback.deinit();
    var pool = pool_mod.Pool.init(buffer, fallback.allocator());
    const value = try parseAllocating(T, pool.allocator(), input, options);

    return .{
        .value = value,
        .buffer = buffer,
        .fallback_arena = fallback,
        .backing_allocator = allocator,
    };
}

fn deserializeValue(comptime T: type, deserializer: *Deserializer) Error!T {
    if (comptime kind.hasCustomDeserialize(T)) {
        return T.jsonzDeserialize(T, deserializer.allocator, deserializer);
    }

    return switch (comptime kind.typeKind(T)) {
        .bool => deserializer.deserializeBool(),
        .int => deserializer.deserializeInt(T),
        .float => deserializer.deserializeFloat(T),
        .string => deserializeStringType(T, deserializer),
        .void => deserializeVoid(deserializer),
        .optional => deserializeOptional(T, deserializer),
        .array => deserializeArray(T, deserializer),
        .slice => deserializeSlice(T, deserializer),
        .tuple => deserializeTuple(T, deserializer),
        .@"struct" => deserializeStruct(T, deserializer),
        .@"enum" => deserializeEnum(T, deserializer),
        .@"union" => deserializeUnion(T, deserializer),
    };
}

fn deserializeVoid(deserializer: *Deserializer) Error!void {
    if (try deserializer.cursor.next() != .null_lit) return error.WrongType;
}

fn deserializeOptional(comptime T: type, deserializer: *Deserializer) Error!T {
    if (try deserializer.cursor.peekIsNull()) {
        _ = try deserializer.cursor.next();
        return null;
    }
    return try deserializeValue(kind.Child(T), deserializer);
}

fn deserializeStringType(comptime T: type, deserializer: *Deserializer) Error!T {
    const value = try deserializer.deserializeString();
    const pointer = @typeInfo(T).pointer;

    if (pointer.size == .slice and pointer.sentinel() == null) return value;
    if (deserializer.borrow_strings) return error.WrongType;

    const sentinel = pointer.sentinel() orelse return error.WrongType;
    const terminated = deserializer.allocator.allocSentinel(u8, value.len, sentinel) catch return error.OutOfMemory;
    @memcpy(terminated, value);
    deserializer.allocator.free(value);
    return if (pointer.size == .many) terminated.ptr else terminated;
}

fn deserializeArray(comptime T: type, deserializer: *Deserializer) Error!T {
    const array = @typeInfo(T).array;
    if (try deserializer.cursor.next() != .array_begin) return error.WrongType;

    var result: T = undefined;
    if (array.len == 0) {
        if (!try deserializer.cursor.isContainerEmpty(']')) return error.WrongType;
        _ = try deserializer.cursor.next();
        return result;
    }

    for (0..array.len) |index| {
        result[index] = try deserializeValue(array.child, deserializer);
        const step = try deserializer.cursor.finishContainer(']');
        if (index + 1 == array.len) {
            if (step != .end) return error.WrongType;
        } else if (step != .more) return error.WrongType;
    }
    return result;
}

fn deserializeSlice(comptime T: type, deserializer: *Deserializer) Error!T {
    const Child = kind.Child(T);
    if (try deserializer.cursor.next() != .array_begin) return error.WrongType;

    var result: std.ArrayList(Child) = .empty;
    errdefer result.deinit(deserializer.allocator);
    // Start small and let the list double. Reserving from the remaining input
    // is only sound when the bytes are the bytes of this array: a document with
    // many small arrays would otherwise reserve, for each one, room for
    // everything that follows it.
    result.ensureTotalCapacity(deserializer.allocator, 8) catch return error.OutOfMemory;
    if (try deserializer.cursor.isContainerEmpty(']')) {
        _ = try deserializer.cursor.next();
        return result.toOwnedSlice(deserializer.allocator) catch error.OutOfMemory;
    }

    while (true) {
        const element = try deserializeValue(Child, deserializer);
        result.append(deserializer.allocator, element) catch return error.OutOfMemory;
        if (try deserializer.cursor.finishContainer(']') == .end) break;
    }
    return result.toOwnedSlice(deserializer.allocator) catch error.OutOfMemory;
}

fn deserializeTuple(comptime T: type, deserializer: *Deserializer) Error!T {
    const fields = comptime kind.structFields(T);
    if (try deserializer.cursor.next() != .array_begin) return error.WrongType;

    var result: T = undefined;
    if (fields.len == 0) {
        if (!try deserializer.cursor.isContainerEmpty(']')) return error.WrongType;
        _ = try deserializer.cursor.next();
        return result;
    }

    inline for (fields, 0..) |field, index| {
        @field(result, field.name) = try deserializeValue(field.type, deserializer);
        const step = try deserializer.cursor.finishContainer(']');
        if (index + 1 == fields.len) {
            if (step != .end) return error.WrongType;
        } else if (step != .more) return error.WrongType;
    }
    return result;
}

fn deserializeStruct(comptime T: type, deserializer: *Deserializer) Error!T {
    const fields = comptime kind.structFields(T);
    if (try deserializer.cursor.next() != .object_begin) return error.WrongType;

    var result: T = undefined;
    var seen: [fields.len]bool = @splat(false);

    if (!try deserializer.cursor.isContainerEmpty('}')) {
        while (true) {
            const raw_key = switch (try deserializer.cursor.next()) {
                .string => |key| key,
                else => return error.WrongType,
            };
            try deserializer.cursor.expectColon();

            const selector = fieldSelector(raw_key);
            var found = false;
            inline for (fields, 0..) |field, index| {
                if (selector == (comptime fieldSelector(field.name)) and std.mem.eql(u8, raw_key, field.name)) {
                    if (seen[index]) return error.UnexpectedToken;
                    @field(result, field.name) = try deserializeValue(field.type, deserializer);
                    seen[index] = true;
                    found = true;
                }
            }
            if (!found) {
                if (!deserializer.options.ignore_unknown_fields) return error.UnknownField;
                try deserializer.cursor.skipValue();
            }
            if (try deserializer.cursor.finishContainer('}') == .end) break;
        }
    } else {
        _ = try deserializer.cursor.next();
    }

    inline for (fields, 0..) |field, index| {
        if (!seen[index]) {
            if (comptime field.defaultValue()) |default| {
                @field(result, field.name) = default;
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else {
                return error.MissingField;
            }
        }
    }
    return result;
}

fn fieldSelector(key: []const u8) u64 {
    if (key.len == 0) return 0;
    return @as(u64, key.len) |
        (@as(u64, key[0]) << 32) |
        (@as(u64, key[key.len - 1]) << 40);
}

fn deserializeEnum(comptime T: type, deserializer: *Deserializer) Error!T {
    const raw = switch (try deserializer.cursor.next()) {
        .string => |value| value,
        else => return error.WrongType,
    };
    inline for (comptime kind.enumFields(T)) |field| {
        if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
    }
    return error.UnexpectedToken;
}

fn deserializeUnion(comptime T: type, deserializer: *Deserializer) Error!T {
    const first = try deserializer.cursor.next();

    if (first == .string) {
        const name = first.string;
        inline for (comptime kind.unionFields(T)) |field| {
            if (field.type == void and std.mem.eql(u8, name, field.name)) return @unionInit(T, field.name, {});
        }
        return error.UnexpectedToken;
    }
    if (first != .object_begin) return error.WrongType;

    const name = switch (try deserializer.cursor.next()) {
        .string => |value| value,
        else => return error.WrongType,
    };
    try deserializer.cursor.expectColon();

    inline for (comptime kind.unionFields(T)) |field| {
        if (std.mem.eql(u8, name, field.name)) {
            const payload = try deserializeValue(field.type, deserializer);
            if (try deserializer.cursor.finishContainer('}') != .end) return error.WrongType;
            return @unionInit(T, field.name, payload);
        }
    }
    return error.UnexpectedToken;
}

fn unescapeString(allocator: Allocator, raw: []const u8) Error![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    result.ensureTotalCapacity(allocator, raw.len) catch return error.OutOfMemory;

    var index: usize = 0;
    while (index < raw.len) {
        if (raw[index] != '\\') {
            result.append(allocator, raw[index]) catch return error.OutOfMemory;
            index += 1;
            continue;
        }

        if (index + 1 >= raw.len) return error.UnexpectedEof;
        switch (raw[index + 1]) {
            '"' => {
                try appendByte(&result, allocator, '"');
                index += 2;
            },
            '\\' => {
                try appendByte(&result, allocator, '\\');
                index += 2;
            },
            '/' => {
                try appendByte(&result, allocator, '/');
                index += 2;
            },
            'b' => {
                try appendByte(&result, allocator, 0x08);
                index += 2;
            },
            'f' => {
                try appendByte(&result, allocator, 0x0c);
                index += 2;
            },
            'n' => {
                try appendByte(&result, allocator, '\n');
                index += 2;
            },
            'r' => {
                try appendByte(&result, allocator, '\r');
                index += 2;
            },
            't' => {
                try appendByte(&result, allocator, '\t');
                index += 2;
            },
            'u' => {
                if (index + 6 > raw.len) return error.UnexpectedEof;
                const codepoint = std.fmt.parseInt(u16, raw[index + 2 .. index + 6], 16) catch return error.InvalidUnicode;
                var decoded: u21 = codepoint;

                if (codepoint >= 0xd800 and codepoint <= 0xdbff) {
                    if (index + 12 > raw.len or raw[index + 6] != '\\' or raw[index + 7] != 'u') {
                        return error.InvalidUnicode;
                    }
                    const low = std.fmt.parseInt(u16, raw[index + 8 .. index + 12], 16) catch return error.InvalidUnicode;
                    if (low < 0xdc00 or low > 0xdfff) return error.InvalidUnicode;
                    decoded = 0x10000 +
                        (@as(u21, codepoint) - 0xd800) * 0x400 +
                        (@as(u21, low) - 0xdc00);
                    index += 12;
                } else if (codepoint >= 0xdc00 and codepoint <= 0xdfff) {
                    return error.InvalidUnicode;
                } else {
                    index += 6;
                }

                var buffer: [4]u8 = undefined;
                const length = std.unicode.utf8Encode(decoded, &buffer) catch return error.InvalidUnicode;
                result.appendSlice(allocator, buffer[0..length]) catch return error.OutOfMemory;
            },
            else => return error.InvalidEscape,
        }
    }
    return result.toOwnedSlice(allocator) catch error.OutOfMemory;
}

fn appendByte(result: *std.ArrayList(u8), allocator: Allocator, byte: u8) Error!void {
    result.append(allocator, byte) catch return error.OutOfMemory;
}
const testing = std.testing;

test "nested values" {
    const User = struct {
        id: u32,
        name: []const u8,
        flags: []const bool,
    };

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const user = try parseAllocating(User, arena.allocator(), "{\"id\":7,\"name\":\"jsonz\",\"flags\":[true,false]}", .{});
    try testing.expectEqual(@as(u32, 7), user.id);
    try testing.expectEqualStrings("jsonz", user.name);
    try testing.expectEqualSlices(bool, &.{ true, false }, user.flags);
}

test "borrowed strings" {
    const input = "\"jsonz\"";
    const value = try parseBorrowed([]const u8, testing.allocator, input, .{});
    try testing.expect(value.ptr == input.ptr + 1);
}

test "custom string token" {
    const StringValue = struct {
        value: []const u8,

        pub fn jsonzDeserialize(
            comptime _: type,
            _: Allocator,
            deserializer: anytype,
        ) Error!@This() {
            const raw = switch (try deserializer.cursor.next()) {
                .string => |string| string,
                else => return error.WrongType,
            };
            return .{ .value = try deserializer.materializeString(raw) };
        }
    };

    const parsed = try parseAllocating(StringValue, testing.allocator, "\"json\\nz\"", .{});
    defer testing.allocator.free(parsed.value);
    try testing.expectEqualStrings("json\nz", parsed.value);
}

test "unicode surrogate pair" {
    const value = try parseAllocating([]const u8, testing.allocator, "\"\\uD83D\\uDE00\"", .{});
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("\u{1F600}", value);
}

test "multiple unicode surrogate pairs" {
    const value = try parseAllocating([]const u8, testing.allocator, "\"\\uD83D\\uDE39\\uD83D\\uDC8D\"", .{});
    defer testing.allocator.free(value);
    try testing.expectEqualStrings("\u{1F639}\u{1F48D}", value);
}

test "unicode noncharacters" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const value = try parseAllocating([]const []const u8, arena.allocator(), "[\"\\uFFFF\",\"\\uFDD0\",\"\\uFFFE\"]", .{});
    try testing.expectEqual(@as(usize, 3), value.len);
}

test "invalid utf8" {
    const cases = [_][]const u8{
        "\"\xff\"",
        "\"\x80\"",
        "\"\xc2\"",
        "\"\xc0\x80\"",
        "\"\xe0\x80\x80\"",
        "\"\xed\xa0\x80\"",
        "\"\xf4\x90\x80\x80\"",
        "\"\xf5\x80\x80\x80\"",
    };
    for (cases) |case| {
        try testing.expectError(error.InvalidUtf8, parseAllocating([]const u8, testing.allocator, case, .{}));
    }

    const valid = try parseAllocating([]const u8, testing.allocator, "\"\xc3\xa9\xe4\xb8\xad\xf0\x9f\x98\x80\"", .{});
    defer testing.allocator.free(valid);
    try testing.expectEqualStrings("\u{e9}\u{4e2d}\u{1f600}", valid);
}

test "float overflow" {
    // JSON has no infinities, so a token that overflows the target type is
    // rejected, matching the DOM and the diagnostic checker.
    try testing.expectError(error.InvalidNumber, parseAllocating(f32, testing.allocator, "1e39", .{}));
    try testing.expectError(error.InvalidNumber, parseAllocating(f64, testing.allocator, "1e309", .{}));
    try testing.expectError(error.InvalidNumber, parseAllocating(f64, testing.allocator, "-1e309", .{}));
    try testing.expectError(error.InvalidNumber, parseAllocating(f64, testing.allocator, "8580858085858085808.5E308", .{}));
    // Underflow stays finite and parses to zero.
    try testing.expectEqual(@as(f64, 0), try parseAllocating(f64, testing.allocator, "1e-400", .{}));
}

test "integer bounds" {
    try testing.expectEqual(std.math.maxInt(u64), try parseAllocating(u64, testing.allocator, "18446744073709551615", .{}));
    try testing.expectEqual(std.math.minInt(i64), try parseAllocating(i64, testing.allocator, "-9223372036854775808", .{}));
    try testing.expectError(error.InvalidNumber, parseAllocating(u64, testing.allocator, "18446744073709551616", .{}));
    try testing.expectError(error.InvalidNumber, parseAllocating(i64, testing.allocator, "9223372036854775808", .{}));
    try testing.expectError(error.InvalidNumber, parseAllocating(i64, testing.allocator, "-9223372036854775809", .{}));
    try testing.expectError(error.InvalidNumber, parseAllocating(u64, testing.allocator, "-1", .{}));
    try testing.expectError(error.InvalidNumber, parseAllocating(u32, testing.allocator, "1.0", .{}));
}

test "caller buffer" {
    const User = struct {
        name: []const u8,
        tags: []const []const u8,
    };

    var buffer: [512]u8 = undefined;
    const user = try parseInto(User, &buffer, "{\"name\":\"jsonz\",\"tags\":[\"zig\",\"json\"]}", .{});

    try testing.expectEqualStrings("jsonz", user.name);
    try testing.expectEqualStrings("zig", user.tags[0]);
    try testing.expectEqualStrings("json", user.tags[1]);
}

test "caller buffer capacity" {
    var buffer: [1]u8 = undefined;
    try testing.expectError(error.OutOfMemory, parseInto([]const u8, &buffer, "\"jsonz\"", .{}));
}

test "parsed value fallback" {
    const input = "[0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0]";
    var parsed = try parse([]const u128, testing.allocator, input, .{});
    defer parsed.deinit();

    try testing.expectEqual(@as(usize, 20), parsed.value.len);
    try testing.expect(parsed.fallback_arena.queryCapacity() != 0);
}

test "many caller-buffer string slices" {
    const Entry = struct {
        name: []const u8,
        tags: []const []const u8,
    };

    // The count of a slice is local to that slice, so sizing one from the
    // bytes left in the document reserves, per array, room for everything that
    // follows it. Enough small arrays here used to exhaust the caller buffer.
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(testing.allocator);
    try input.appendSlice(testing.allocator, "[");
    for (0..200) |index| {
        var piece: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&piece, "{s}{{\"name\":\"n{d}\",\"tags\":[\"a\",\"b\"]}}", .{
            if (index == 0) "" else ",",
            index,
        });
        try input.appendSlice(testing.allocator, text);
    }
    try input.appendSlice(testing.allocator, "]");

    var buffer: [256 * 1024]u8 = undefined;
    const entries = try parseInto([]const Entry, &buffer, input.items, .{});
    try testing.expectEqual(@as(usize, 200), entries.len);
    try testing.expectEqualStrings("n0", entries[0].name);
    try testing.expectEqualStrings("b", entries[199].tags[1]);
}
