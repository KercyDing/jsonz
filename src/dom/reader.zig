const std = @import("std");
const float = @import("float");
const pool_mod = @import("pool.zig");

const Pool = pool_mod.Pool;
const Subtype = pool_mod.Subtype;
const Type = pool_mod.Type;
const Value = pool_mod.Value;

/// Options that control DOM parsing, matching yyjson's read flags.
pub const Options = struct {
    /// Accept `//` and `/* ... */` comments, which are not part of standard JSON.
    allow_comments: bool = false,
    /// Accept a comma before a closing `]` or `}`, which is not part of standard JSON.
    allow_trailing_commas: bool = false,
};

pub const Error = error{ InvalidJson, OutOfMemory };

/// Parses the JSON in `input` into `pool` and returns the root value index.
///
/// `input` must stay mutable and alive as long as the pool is read: string
/// escape sequences are decoded in place, and every string value stores a byte
/// offset into `input`.
pub fn read(pool: *Pool, input: []u8, options: Options) Error!u32 {
    var reader: Reader = .{
        .input = input,
        .pool = pool,
        .options = options,
    };
    return reader.run();
}

const State = enum {
    root,
    array_value,
    array_end,
    object_key,
    object_colon,
    object_value,
    object_end,
    done,
};

/// A goto-free port of yyjson's reader finite state machine.
const Reader = struct {
    input: []u8,
    pool: *Pool,
    options: Options,
    pos: usize = 0,
    /// The container currently being read.
    current: u32 = 0,
    /// Elements finished in an array, or key/value slots finished in an object.
    count: usize = 0,
    /// The value most recently appended.
    last: u32 = 0,

    fn run(self: *Reader) Error!u32 {
        var state: State = .root;
        var root: ?u32 = null;

        while (state != .done) {
            try self.skipTrivia();
            switch (state) {
                .root => {
                    if (self.pos == self.input.len) return error.InvalidJson;
                    if (try self.beginValue(null)) |container_state| {
                        root = self.current;
                        state = container_state;
                    } else {
                        root = self.last;
                        try self.skipTrivia();
                        if (self.pos != self.input.len) return error.InvalidJson;
                        state = .done;
                    }
                },
                .array_value => {
                    if (try self.consume(']')) {
                        state = try self.closeContainer();
                        continue;
                    }
                    if (try self.beginValue(self.current)) |container_state| {
                        state = container_state;
                    } else {
                        self.count += 1;
                        state = .array_end;
                    }
                },
                .array_end => {
                    if (try self.consume(',')) {
                        if (try self.peek(']')) {
                            if (!self.options.allow_trailing_commas) return error.InvalidJson;
                            self.pos += 1;
                            state = try self.closeContainer();
                        } else state = .array_value;
                    } else if (try self.consume(']')) {
                        state = try self.closeContainer();
                    } else return error.InvalidJson;
                },
                .object_key => {
                    if (try self.consume('}')) {
                        state = try self.closeContainer();
                        continue;
                    }
                    if (self.pos == self.input.len or self.input[self.pos] != '"') return error.InvalidJson;
                    _ = try self.readString();
                    self.count += 1;
                    state = .object_colon;
                },
                .object_colon => {
                    if (!try self.consume(':')) return error.InvalidJson;
                    state = .object_value;
                },
                .object_value => {
                    if (try self.beginValue(self.current)) |container_state| {
                        state = container_state;
                    } else {
                        self.count += 1;
                        state = .object_end;
                    }
                },
                .object_end => {
                    if (try self.consume(',')) {
                        if (try self.peek('}')) {
                            if (!self.options.allow_trailing_commas) return error.InvalidJson;
                            self.pos += 1;
                            state = try self.closeContainer();
                        } else state = .object_key;
                    } else if (try self.consume('}')) {
                        state = try self.closeContainer();
                    } else return error.InvalidJson;
                },
                .done => unreachable,
            }
        }
        return root orelse unreachable;
    }

    /// Appends either a scalar or a container header. A container saves the
    /// distance to its parent in `uni` until it is closed.
    fn beginValue(self: *Reader, parent: ?u32) Error!?State {
        if (self.pos == self.input.len) return error.InvalidJson;
        switch (self.input[self.pos]) {
            '[' => {
                self.last = try self.beginContainer(.array, parent);
                return .array_value;
            },
            '{' => {
                self.last = try self.beginContainer(.object, parent);
                return .object_key;
            },
            '"' => self.last = try self.readString(),
            't' => self.last = try self.readLiteral("true", .bool, pool_mod.true_value, 1),
            'f' => self.last = try self.readLiteral("false", .bool, pool_mod.false_value, 0),
            'n' => self.last = try self.readLiteral("null", .null, .none, 0),
            '-', '0'...'9' => self.last = try self.readNumber(),
            else => return error.InvalidJson,
        }
        return null;
    }

    fn beginContainer(self: *Reader, value_type: Type, parent: ?u32) Error!u32 {
        self.pos += 1;
        const container = try self.append(.{
            .tag = pool_mod.makeTag(value_type, .none, 0),
            .uni = .{ .uint = 0 },
        });
        if (parent) |parent_index| {
            // Count the new child in the parent. For an array this is its final
            // length; for an object it is the number of finished key/value
            // slots, converted to a pair count when the object closes.
            const parent_value = self.pool.at(parent_index).*;
            self.pool.atMut(parent_index).tag = pool_mod.makeTag(
                pool_mod.valueType(parent_value),
                .none,
                self.count + 1,
            );
            self.pool.atMut(container).uni.offset = pool_mod.byteOffset(parent_index, container);
        }
        self.current = container;
        self.count = 0;
        return container;
    }

    fn closeContainer(self: *Reader) Error!State {
        const container = self.current;
        const value = self.pool.at(container).*;
        const value_type = pool_mod.valueType(value);
        const parent = container - @as(u32, @intCast(value.uni.offset / pool_mod.value_size));
        const len = if (value_type == .object) self.count / 2 else self.count;
        // The offset points one value past the last child, so that walking
        // siblings can skip this whole subtree.
        self.pool.atMut(container).* = .{
            .tag = pool_mod.makeTag(value_type, .none, len),
            .uni = .{ .offset = pool_mod.byteOffset(container, @intCast(self.pool.len)) },
        };
        if (parent == container) {
            try self.skipTrivia();
            if (self.pos != self.input.len) return error.InvalidJson;
            return .done;
        }

        self.current = parent;
        self.count = pool_mod.valueLen(self.pool.at(parent).*);
        return if (pool_mod.valueType(self.pool.at(parent).*) == .object) .object_end else .array_end;
    }

    fn readLiteral(
        self: *Reader,
        comptime text: []const u8,
        value_type: Type,
        subtype: Subtype,
        payload: u64,
    ) Error!u32 {
        if (self.pos + text.len > self.input.len or
            !std.mem.eql(u8, self.input[self.pos..][0..text.len], text))
        {
            return error.InvalidJson;
        }
        self.pos += text.len;
        return self.append(.{
            .tag = pool_mod.makeTag(value_type, subtype, 0),
            .uni = .{ .uint = payload },
        });
    }

    fn readNumber(self: *Reader) Error!u32 {
        const start = self.pos;
        if (self.input[self.pos] == '-') self.pos += 1;
        if (self.pos == self.input.len) return error.InvalidJson;
        if (self.input[self.pos] == '0') {
            self.pos += 1;
        } else if (self.input[self.pos] >= '1' and self.input[self.pos] <= '9') {
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        } else return error.InvalidJson;

        var real = false;
        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            real = true;
            self.pos += 1;
            if (self.pos == self.input.len or !std.ascii.isDigit(self.input[self.pos])) return error.InvalidJson;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        }
        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            real = true;
            self.pos += 1;
            if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) self.pos += 1;
            if (self.pos == self.input.len or !std.ascii.isDigit(self.input[self.pos])) return error.InvalidJson;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        }
        const raw = self.input[start..self.pos];

        if (!real) {
            // An integer that fits is kept exact; yyjson demotes anything
            // larger to a double, which the fallback below does too.
            if (raw[0] == '-') {
                if (std.fmt.parseInt(i64, raw, 10)) |number| {
                    return self.append(.{
                        .tag = pool_mod.makeTag(.number, pool_mod.sint, 0),
                        .uni = .{ .int = number },
                    });
                } else |_| {}
            } else {
                if (std.fmt.parseInt(u64, raw, 10)) |number| {
                    return self.append(.{
                        .tag = pool_mod.makeTag(.number, pool_mod.uint, 0),
                        .uni = .{ .uint = number },
                    });
                } else |_| {}
            }
        }

        const number = float.parseNumber(f64, self.input, start) catch return error.InvalidJson;
        if (!std.math.isFinite(number.value)) return error.InvalidJson;
        return self.append(.{
            .tag = pool_mod.makeTag(.number, .real, 0),
            .uni = .{ .float = number.value },
        });
    }

    /// Reads a string value, decoding escapes in place.
    ///
    /// Strings without escapes take a scan-only fast path that never writes to
    /// the input buffer; the common case in real documents.
    fn readString(self: *Reader) Error!u32 {
        self.pos += 1;
        const start = self.pos;

        var scan = start;
        while (scan < self.input.len) {
            const byte = self.input[scan];
            if (byte == '"') {
                self.pos = scan + 1;
                return self.append(.{
                    .tag = pool_mod.makeTag(.string, pool_mod.no_escape, scan - start),
                    .uni = .{ .offset = start },
                });
            }
            if (byte == '\\') break;
            if (byte < 0x20) return error.InvalidJson;
            if (byte < 0x80) {
                scan += 1;
            } else {
                scan += try self.utf8SequenceLen(scan);
            }
        }
        if (scan == self.input.len) return error.InvalidJson;

        // At least one escape: decode the rest in place. `write` trails `scan`
        // because escape sequences shrink.
        self.pos = scan;
        var write = scan;
        while (self.pos < self.input.len) {
            const byte = self.input[self.pos];
            switch (byte) {
                '"' => {
                    self.pos += 1;
                    return self.append(.{
                        .tag = pool_mod.makeTag(.string, .none, write - start),
                        .uni = .{ .offset = start },
                    });
                },
                '\\' => {
                    self.pos += 1;
                    if (self.pos == self.input.len) return error.InvalidJson;
                    const escape = self.input[self.pos];
                    self.pos += 1;
                    if (escape == 'u') {
                        write = try self.readUnicodeEscape(write);
                        continue;
                    }
                    const decoded: u8 = switch (escape) {
                        '"', '\\', '/' => escape,
                        'b' => 0x08,
                        'f' => 0x0c,
                        'n' => '\n',
                        'r' => '\r',
                        't' => '\t',
                        else => return error.InvalidJson,
                    };
                    self.input[write] = decoded;
                    write += 1;
                },
                0x00...0x1f => return error.InvalidJson,
                else => {
                    if (byte < 0x80) {
                        self.input[write] = byte;
                        write += 1;
                        self.pos += 1;
                    } else {
                        const seq_len = try self.utf8SequenceLen(self.pos);
                        // `write` never passes `self.pos`, so copy forwards.
                        std.mem.copyForwards(
                            u8,
                            self.input[write..][0..seq_len],
                            self.input[self.pos..][0..seq_len],
                        );
                        write += seq_len;
                        self.pos += seq_len;
                    }
                },
            }
        }
        return error.InvalidJson;
    }

    /// Validates one UTF-8 sequence at `pos` and returns its byte length.
    ///
    /// yyjson validates UTF-8 by default, so this rejects lone continuation
    /// bytes, overlong forms, surrogates, and code points beyond U+10FFFF.
    fn utf8SequenceLen(self: *Reader, pos: usize) Error!usize {
        const seq_len: usize = std.unicode.utf8ByteSequenceLength(self.input[pos]) catch
            return error.InvalidJson;
        if (pos + seq_len > self.input.len) return error.InvalidJson;
        _ = std.unicode.utf8Decode(self.input[pos..][0..seq_len]) catch
            return error.InvalidJson;
        return seq_len;
    }

    /// Decodes `\uXXXX`, including surrogate pairs, into UTF-8 at `write`.
    fn readUnicodeEscape(self: *Reader, write: usize) Error!usize {
        var codepoint: u21 = try self.readHex4();
        if (codepoint >= 0xd800 and codepoint <= 0xdbff) {
            if (self.pos + 2 > self.input.len or
                self.input[self.pos] != '\\' or self.input[self.pos + 1] != 'u')
            {
                return error.InvalidJson;
            }
            self.pos += 2;
            const low = try self.readHex4();
            if (low < 0xdc00 or low > 0xdfff) return error.InvalidJson;
            codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00);
        } else if (codepoint >= 0xdc00 and codepoint <= 0xdfff) {
            return error.InvalidJson;
        }

        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &bytes) catch return error.InvalidJson;
        @memcpy(self.input[write..][0..len], bytes[0..len]);
        return write + len;
    }

    fn readHex4(self: *Reader) Error!u21 {
        if (self.pos + 4 > self.input.len) return error.InvalidJson;
        var value: u21 = 0;
        for (self.input[self.pos..][0..4]) |byte| {
            const digit: u21 = switch (byte) {
                '0'...'9' => byte - '0',
                'a'...'f' => byte - 'a' + 10,
                'A'...'F' => byte - 'A' + 10,
                else => return error.InvalidJson,
            };
            value = (value << 4) | digit;
        }
        self.pos += 4;
        return value;
    }

    fn append(self: *Reader, value: Value) Error!u32 {
        return self.pool.append(value) catch return error.OutOfMemory;
    }

    fn skipTrivia(self: *Reader) Error!void {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                '/' => if (self.options.allow_comments) try self.skipComment() else return,
                else => return,
            }
        }
    }

    fn skipComment(self: *Reader) Error!void {
        if (self.pos + 1 >= self.input.len) return error.InvalidJson;
        const kind = self.input[self.pos + 1];
        self.pos += 2;
        if (kind == '/') {
            while (self.pos < self.input.len and
                self.input[self.pos] != '\n' and self.input[self.pos] != '\r')
            {
                self.pos += 1;
            }
            return;
        }
        if (kind != '*') return error.InvalidJson;
        while (self.pos + 1 < self.input.len) : (self.pos += 1) {
            if (self.input[self.pos] == '*' and self.input[self.pos + 1] == '/') {
                self.pos += 2;
                return;
            }
        }
        return error.InvalidJson;
    }

    fn consume(self: *Reader, byte: u8) Error!bool {
        try self.skipTrivia();
        if (self.pos >= self.input.len or self.input[self.pos] != byte) return false;
        self.pos += 1;
        return true;
    }

    fn peek(self: *Reader, byte: u8) Error!bool {
        try self.skipTrivia();
        return self.pos < self.input.len and self.input[self.pos] == byte;
    }
};

fn readWithOptions(input: []u8, options: Options, allocator: std.mem.Allocator) !struct { Pool, u32 } {
    var pool = try Pool.init(allocator, input.len, false);
    errdefer pool.deinit();
    const root = try read(&pool, input, options);
    return .{ pool, root };
}

test "nested values" {
    var input = "{\"items\":[1,{\"ok\":true}],\"name\":\"json\"}".*;
    var result = try readWithOptions(&input, .{}, std.testing.allocator);
    defer result[0].deinit();
    const pool = &result[0];
    try std.testing.expectEqual(Type.object, pool_mod.valueType(pool.at(result[1]).*));
    try std.testing.expectEqual(@as(usize, 2), pool_mod.valueLen(pool.at(result[1]).*));
    // 1 root object + 2 keys + 2 values (array, string) + 3 array items =
    // 9 values, keys included.
    try std.testing.expectEqual(@as(usize, 9), pool.items().len);
}

test "trailing comma" {
    var input = "[1,]".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&input, .{}, std.testing.allocator));
    var allowed = "[1,]".*;
    var result = try readWithOptions(&allowed, .{ .allow_trailing_commas = true }, std.testing.allocator);
    defer result[0].deinit();
}

test "comments" {
    var input = "/* lead */ {\"a\": 1 // tail\n}".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&input, .{}, std.testing.allocator));
    var result = try readWithOptions(&input, .{ .allow_comments = true }, std.testing.allocator);
    defer result[0].deinit();
    try std.testing.expectEqual(@as(usize, 3), result[0].items().len);
}

test "unicode escapes" {
    const cases = .{
        .{ "\"\\u0041\"", "A" },
        .{ "\"\\u00e9\"", "\u{e9}" },
        .{ "\"\\u4e2d\"", "\u{4e2d}" },
        .{ "\"\\uD83D\\uDE00\"", "\u{1f600}" },
        .{ "\"\\u0000\"", "\x00" },
    };
    inline for (cases) |case| {
        var input = case[0].*;
        var result = try readWithOptions(&input, .{}, std.testing.allocator);
        defer result[0].deinit();
        const value = result[0].at(result[1]).*;
        try std.testing.expectEqualStrings(
            case[1],
            input[@intCast(value.uni.offset)..][0..pool_mod.valueLen(value)],
        );
    }
}

test "invalid unicode escapes" {
    var lone_high = "\"\\uD800\"".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&lone_high, .{}, std.testing.allocator));
    var lone_low = "\"\\uDC00\"".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&lone_low, .{}, std.testing.allocator));
    var bad = "\"\\uZZZZ\"".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&bad, .{}, std.testing.allocator));
}

test "invalid UTF-8 in strings" {
    var invalid_lead = "\"\xff\"".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&invalid_lead, .{}, std.testing.allocator));
    var overlong = "\"\xc0\x80\"".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&overlong, .{}, std.testing.allocator));
    var surrogate = "\"\xed\xa0\x80\"".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&surrogate, .{}, std.testing.allocator));
    var truncated = "\"\xc2\"".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&truncated, .{}, std.testing.allocator));

    var valid = "\"\xe4\xb8\xad\"".*;
    var result = try readWithOptions(&valid, .{}, std.testing.allocator);
    defer result[0].deinit();
}

test "number subtypes" {
    const Case = struct { text: []const u8, subtype: Subtype, bits: u64 };
    const cases = [_]Case{
        .{ .text = "0", .subtype = pool_mod.uint, .bits = 0 },
        .{ .text = "-0", .subtype = pool_mod.sint, .bits = 0 },
        .{ .text = "42", .subtype = pool_mod.uint, .bits = 42 },
        .{ .text = "-42", .subtype = pool_mod.sint, .bits = @bitCast(@as(i64, -42)) },
        .{ .text = "18446744073709551615", .subtype = pool_mod.uint, .bits = std.math.maxInt(u64) },
        // Values beyond the integer range become doubles.
        .{ .text = "18446744073709551616", .subtype = .real, .bits = @bitCast(@as(f64, 18446744073709551616)) },
        .{ .text = "-9223372036854775808", .subtype = pool_mod.sint, .bits = @bitCast(@as(i64, std.math.minInt(i64))) },
        .{ .text = "1.5", .subtype = .real, .bits = @bitCast(@as(f64, 1.5)) },
        .{ .text = "1e3", .subtype = .real, .bits = @bitCast(@as(f64, 1000)) },
    };
    inline for (cases) |case| {
        var result = try readWithOptions(@constCast(case.text), .{}, std.testing.allocator);
        defer result[0].deinit();
        const value = result[0].at(result[1]).*;
        try std.testing.expectEqual(Type.number, pool_mod.valueType(value));
        try std.testing.expectEqual(case.subtype, pool_mod.valueSubtype(value));
        try std.testing.expectEqual(case.bits, value.uni.uint);
    }
}

test "invalid numbers" {
    const cases = [_][]const u8{
        "01", "-", "1.", ".1", "1e", "1e+", "+1", "1e309",
    };
    for (cases) |case| {
        try std.testing.expectError(
            error.InvalidJson,
            readWithOptions(@constCast(case), .{}, std.testing.allocator),
        );
    }
}
