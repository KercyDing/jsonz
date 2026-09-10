const std = @import("std");
const pool_mod = @import("pool.zig");

const Pool = pool_mod.Pool;
const Subtype = pool_mod.Subtype;
const Type = pool_mod.Type;
const Value = pool_mod.Value;

pub const Options = struct {
    allow_trailing_commas: bool = false,
};

pub const Error = error{ InvalidJson, OutOfMemory };

pub const Result = struct {
    pool: Pool,
    root: u32,

    pub fn deinit(self: *Result) void {
        self.pool.deinit();
        self.* = undefined;
    }
};

/// Reads a mutable input buffer into a compact, contiguous value pool.
/// String escapes are decoded in place, so all string offsets remain valid for
/// the lifetime of `input`.
pub fn read(allocator: std.mem.Allocator, input: []u8, options: Options) Error!Result {
    var reader: Reader = .{
        .input = input,
        .pool = Pool.init(allocator, input.len, hasWhitespace(input)) catch return error.OutOfMemory,
        .options = options,
    };
    errdefer reader.pool.deinit();

    const root = try reader.run();
    return .{ .pool = reader.pool, .root = root };
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

const Reader = struct {
    input: []u8,
    pool: Pool,
    options: Options,
    pos: usize = 0,
    current: u32 = 0,
    count: usize = 0,
    last: u32 = 0,

    fn run(self: *Reader) Error!u32 {
        var state: State = .root;
        var root: ?u32 = null;

        while (state != .done) {
            self.skipWhitespace();
            switch (state) {
                .root => {
                    if (self.pos == self.input.len) return error.InvalidJson;
                    if (try self.beginValue(null)) |container_state| {
                        root = self.current;
                        state = container_state;
                    } else {
                        root = self.last;
                        self.skipWhitespace();
                        if (self.pos != self.input.len) return error.InvalidJson;
                        state = .done;
                    }
                },
                .array_value => {
                    if (self.consume(']')) {
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
                    if (self.consume(',')) {
                        self.skipWhitespace();
                        if (self.peek(']')) {
                            if (!self.options.allow_trailing_commas) return error.InvalidJson;
                            self.pos += 1;
                            state = try self.closeContainer();
                        } else state = .array_value;
                    } else if (self.consume(']')) {
                        state = try self.closeContainer();
                    } else return error.InvalidJson;
                },
                .object_key => {
                    if (self.consume('}')) {
                        state = try self.closeContainer();
                        continue;
                    }
                    if (self.pos == self.input.len or self.input[self.pos] != '"') return error.InvalidJson;
                    _ = try self.readString();
                    self.count += 1;
                    state = .object_colon;
                },
                .object_colon => {
                    if (!self.consume(':')) return error.InvalidJson;
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
                    if (self.consume(',')) {
                        self.skipWhitespace();
                        if (self.peek('}')) {
                            if (!self.options.allow_trailing_commas) return error.InvalidJson;
                            self.pos += 1;
                            state = try self.closeContainer();
                        } else state = .object_key;
                    } else if (self.consume('}')) {
                        state = try self.closeContainer();
                    } else return error.InvalidJson;
                },
                .done => unreachable,
            }
        }
        return root orelse unreachable;
    }

    /// Appends either a scalar or a container header. A container saves the
    /// parent distance in `uni` until it is closed.
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
        const index = self.append(.{ .tag = pool_mod.makeTag(value_type, .none, 0), .uni = 0 });
        const container = try index;
        if (parent) |parent_index| {
            self.pool.atMut(parent_index).tag = pool_mod.makeTag(pool_mod.valueType(self.pool.at(parent_index).*), .none, self.count + 1);
            self.pool.atMut(container).uni = pool_mod.byteOffset(parent_index, container);
        }
        self.current = container;
        self.count = 0;
        return container;
    }

    fn closeContainer(self: *Reader) Error!State {
        const container = self.current;
        const value_type = pool_mod.valueType(self.pool.at(container).*);
        const parent_offset = self.pool.at(container).uni;
        const parent = container - @as(u32, @intCast(parent_offset / pool_mod.value_size));
        const len = if (value_type == .object) self.count / 2 else self.count;
        self.pool.atMut(container).* = .{
            .tag = pool_mod.makeTag(value_type, .none, len),
            .uni = pool_mod.byteOffset(container, @intCast(self.pool.values.items.len)),
        };
        if (parent == container) {
            self.skipWhitespace();
            if (self.pos != self.input.len) return error.InvalidJson;
            return .done;
        }

        self.current = parent;
        self.count = pool_mod.valueLen(self.pool.at(parent).*);
        return if (pool_mod.valueType(self.pool.at(parent).*) == .object) .object_end else .array_end;
    }

    fn readLiteral(self: *Reader, comptime text: []const u8, value_type: Type, subtype: Subtype, payload: u64) Error!u32 {
        if (self.pos + text.len > self.input.len or !std.mem.eql(u8, self.input[self.pos..][0..text.len], text)) return error.InvalidJson;
        self.pos += text.len;
        return self.append(.{ .tag = pool_mod.makeTag(value_type, subtype, 0), .uni = payload });
    }

    fn readNumber(self: *Reader) Error!u32 {
        const start = self.pos;
        if (self.input[self.pos] == '-') self.pos += 1;
        if (self.pos == self.input.len) return error.InvalidJson;
        if (self.input[self.pos] == '0') self.pos += 1 else if (self.input[self.pos] >= '1' and self.input[self.pos] <= '9') {
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
        if (real) {
            const number = std.fmt.parseFloat(f64, raw) catch return error.InvalidJson;
            if (!std.math.isFinite(number)) return error.InvalidJson;
            return self.append(.{ .tag = pool_mod.makeTag(.number, .real, 0), .uni = @bitCast(number) });
        }
        if (raw[0] == '-') {
            const number = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidJson;
            return self.append(.{ .tag = pool_mod.makeTag(.number, pool_mod.sint, 0), .uni = @bitCast(number) });
        }
        const number = std.fmt.parseInt(u64, raw, 10) catch return error.InvalidJson;
        return self.append(.{ .tag = pool_mod.makeTag(.number, pool_mod.uint, 0), .uni = number });
    }

    fn readString(self: *Reader) Error!u32 {
        self.pos += 1;
        const start = self.pos;
        var write = start;
        var escaped = false;
        while (self.pos < self.input.len) {
            const byte = self.input[self.pos];
            switch (byte) {
                '"' => {
                    self.pos += 1;
                    const len = write - start;
                    return self.append(.{
                        .tag = pool_mod.makeTag(.string, if (escaped) .none else pool_mod.no_escape, len),
                        .uni = start,
                    });
                },
                '\\' => {
                    escaped = true;
                    self.pos += 1;
                    if (self.pos == self.input.len) return error.InvalidJson;
                    const escape = self.input[self.pos];
                    self.pos += 1;
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
                    self.input[write] = byte;
                    write += 1;
                    self.pos += 1;
                },
            }
        }
        return error.InvalidJson;
    }

    fn append(self: *Reader, value: Value) Error!u32 {
        return self.pool.append(value) catch return error.OutOfMemory;
    }

    fn skipWhitespace(self: *Reader) void {
        while (self.pos < self.input.len) switch (self.input[self.pos]) {
            ' ', '\t', '\n', '\r' => self.pos += 1,
            else => return,
        };
    }

    fn consume(self: *Reader, byte: u8) bool {
        self.skipWhitespace();
        if (!self.peek(byte)) return false;
        self.pos += 1;
        return true;
    }

    fn peek(self: *Reader, byte: u8) bool {
        self.skipWhitespace();
        return self.pos < self.input.len and self.input[self.pos] == byte;
    }
};

fn hasWhitespace(input: []const u8) bool {
    return std.mem.indexOfAny(u8, input, " \t\n\r") != null;
}

test "nested values" {
    var input = "{\"items\":[1,{\"ok\":true}],\"name\":\"json\"}".*;
    var result = try read(std.testing.allocator, &input, .{});
    defer result.deinit();
    try std.testing.expectEqual(Type.object, pool_mod.valueType(result.pool.at(result.root).*));
    try std.testing.expectEqual(@as(usize, 2), pool_mod.valueLen(result.pool.at(result.root).*));
    try std.testing.expectEqual(@as(usize, 9), result.pool.values.items.len);
}

test "trailing comma" {
    var input = "[1,]".*;
    try std.testing.expectError(error.InvalidJson, read(std.testing.allocator, &input, .{}));
}
