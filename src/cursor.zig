const std = @import("std");

const string_char_table = blk: {
    var table: [256]u8 = undefined;
    for (&table, 0..) |*entry, byte| {
        entry.* = if (byte < 0x20 or byte == '"' or byte == '\\') 1 else 0;
    }
    break :blk table;
};

pub const Token = union(enum) {
    object_begin,
    object_end,
    array_begin,
    array_end,
    string: []const u8,
    number: []const u8,
    true_lit,
    false_lit,
    null_lit,
};

pub const Error = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    InvalidEscape,
    InvalidControlCharacter,
    MaxDepthExceeded,
};

pub const Cursor = struct {
    input: []const u8,
    pos: usize = 0,
    depth: u32 = 0,
    max_depth: u32 = 256,
    last_string_has_escape: bool = false,

    pub inline fn next(self: *Cursor) Error!Token {
        self.skipWhitespace();
        if (self.pos == self.input.len) return error.UnexpectedEof;

        return switch (self.input[self.pos]) {
            '{' => self.openContainer(.object_begin),
            '[' => self.openContainer(.array_begin),
            '}' => self.closeContainer(.object_end),
            ']' => self.closeContainer(.array_end),
            '"' => .{ .string = try self.scanString() },
            '-', '0'...'9' => .{ .number = try self.scanNumber() },
            't' => self.scanLiteral("true", .true_lit),
            'f' => self.scanLiteral("false", .false_lit),
            'n' => self.scanLiteral("null", .null_lit),
            else => error.UnexpectedToken,
        };
    }

    pub fn peek(self: *Cursor) Error!Token {
        const pos = self.pos;
        const depth = self.depth;
        const last_string_has_escape = self.last_string_has_escape;
        defer {
            self.pos = pos;
            self.depth = depth;
            self.last_string_has_escape = last_string_has_escape;
        }
        return self.next();
    }

    pub fn expectColon(self: *Cursor) Error!void {
        self.skipWhitespace();
        if (self.pos == self.input.len) return error.UnexpectedEof;
        if (self.input[self.pos] != ':') return error.UnexpectedToken;
        self.pos += 1;
    }

    pub inline fn readInt(self: *Cursor, comptime T: type) Error!T {
        self.skipWhitespace();
        if (self.pos == self.input.len) return error.UnexpectedEof;

        const input = self.input;
        var pos = self.pos;
        const negative = input[pos] == '-';
        if (negative) pos += 1;
        if (pos == input.len) return error.InvalidNumber;

        var value: u64 = 0;
        const first = input[pos];
        if (first == '0') {
            pos += 1;
        } else if (first >= '1' and first <= '9') {
            while (pos < input.len) {
                const byte = input[pos];
                if (byte < '0' or byte > '9') break;
                const multiplied = @mulWithOverflow(value, 10);
                if (multiplied[1] != 0) return error.InvalidNumber;
                const added = @addWithOverflow(multiplied[0], byte - '0');
                if (added[1] != 0) return error.InvalidNumber;
                value = added[0];
                pos += 1;
            }
        } else if (!negative) {
            return error.UnexpectedToken;
        } else {
            return error.InvalidNumber;
        }

        if (pos < input.len) {
            const next_byte = input[pos];
            if (next_byte == '.' or next_byte == 'e' or next_byte == 'E') return error.InvalidNumber;
        }

        const int = @typeInfo(T).int;
        const result: T = if (int.signedness == .unsigned) result: {
            if (negative) return error.InvalidNumber;
            break :result std.math.cast(T, value) orelse return error.InvalidNumber;
        } else result: {
            const positive_limit: u64 = @intCast(std.math.maxInt(T));
            if (!negative) {
                if (value > positive_limit) return error.InvalidNumber;
                break :result @intCast(value);
            }

            const negative_limit = positive_limit + 1;
            if (value > negative_limit) return error.InvalidNumber;
            if (value == negative_limit) break :result std.math.minInt(T);
            break :result -@as(T, @intCast(value));
        };
        self.pos = pos;
        return result;
    }

    pub const ContainerStep = enum { end, more };

    pub inline fn finishContainer(self: *Cursor, end: u8) Error!ContainerStep {
        self.skipWhitespace();
        if (self.pos == self.input.len) return error.UnexpectedEof;

        if (self.input[self.pos] == end) {
            self.pos += 1;
            self.depth -= 1;
            return .end;
        }
        if (self.input[self.pos] != ',') return error.UnexpectedToken;

        self.pos += 1;
        self.skipWhitespace();
        if (self.pos == self.input.len) return error.UnexpectedEof;
        if (self.input[self.pos] == end) return error.UnexpectedToken;
        return .more;
    }

    pub fn isContainerEmpty(self: *Cursor, end: u8) Error!bool {
        self.skipWhitespace();
        if (self.pos == self.input.len) return error.UnexpectedEof;
        return self.input[self.pos] == end;
    }

    pub fn skipValue(self: *Cursor) Error!void {
        self.skipWhitespace();
        if (self.pos == self.input.len) return error.UnexpectedEof;

        switch (self.input[self.pos]) {
            '{' => {
                try self.openSkippedContainer();
                if (try self.consumeEmpty('}')) return;
                while (true) {
                    self.skipWhitespace();
                    if (self.pos == self.input.len) return error.UnexpectedEof;
                    if (self.input[self.pos] != '"') return error.UnexpectedToken;
                    _ = try self.scanString();
                    try self.expectColon();
                    try self.skipValue();
                    if (try self.finishContainer('}') == .end) return;
                }
            },
            '[' => {
                try self.openSkippedContainer();
                if (try self.consumeEmpty(']')) return;
                while (true) {
                    try self.skipValue();
                    if (try self.finishContainer(']') == .end) return;
                }
            },
            '"' => _ = try self.scanString(),
            '-', '0'...'9' => _ = try self.scanNumber(),
            't' => try self.skipLiteral("true"),
            'f' => try self.skipLiteral("false"),
            'n' => try self.skipLiteral("null"),
            else => return error.UnexpectedToken,
        }
    }

    pub fn finish(self: *Cursor) Error!void {
        self.skipWhitespace();
        if (self.pos != self.input.len) return error.UnexpectedToken;
    }

    fn openContainer(self: *Cursor, token: Token) Error!Token {
        if (self.depth == self.max_depth) return error.MaxDepthExceeded;
        self.depth += 1;
        self.pos += 1;
        return token;
    }

    fn closeContainer(self: *Cursor, token: Token) Error!Token {
        if (self.depth == 0) return error.UnexpectedToken;
        self.depth -= 1;
        self.pos += 1;
        return token;
    }

    inline fn openSkippedContainer(self: *Cursor) Error!void {
        if (self.depth == self.max_depth) return error.MaxDepthExceeded;
        self.depth += 1;
        self.pos += 1;
    }

    fn consumeEmpty(self: *Cursor, end: u8) Error!bool {
        if (!try self.isContainerEmpty(end)) return false;
        self.pos += 1;
        self.depth -= 1;
        return true;
    }

    fn scanString(self: *Cursor) Error![]const u8 {
        const input = self.input;
        var pos = self.pos + 1;
        const start = pos;
        var has_escape = false;

        while (pos + 4 <= input.len) {
            const a = input[pos];
            const b = input[pos + 1];
            const c = input[pos + 2];
            const d = input[pos + 3];
            if ((string_char_table[a] | string_char_table[b] |
                string_char_table[c] | string_char_table[d]) == 0)
            {
                pos += 4;
            } else break;
        }

        while (pos < input.len) {
            switch (input[pos]) {
                '"' => {
                    self.pos = pos + 1;
                    self.last_string_has_escape = has_escape;
                    return input[start..pos];
                },
                '\\' => {
                    has_escape = true;
                    pos += 1;
                    if (pos == input.len) return error.UnexpectedEof;
                    switch (input[pos]) {
                        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => pos += 1,
                        'u' => {
                            if (pos + 5 > input.len) return error.UnexpectedEof;
                            for (input[pos + 1 .. pos + 5]) |digit| {
                                if (!std.ascii.isHex(digit)) return error.InvalidEscape;
                            }
                            pos += 5;
                        },
                        else => return error.InvalidEscape,
                    }
                },
                0x00...0x1f => return error.InvalidControlCharacter,
                else => pos += 1,
            }
        }
        return error.UnexpectedEof;
    }

    fn scanNumber(self: *Cursor) Error![]const u8 {
        const input = self.input;
        const start = self.pos;
        var pos = start;
        if (input[pos] == '-') pos += 1;
        if (pos == input.len) return error.InvalidNumber;

        if (input[pos] == '0') {
            pos += 1;
        } else if (input[pos] >= '1' and input[pos] <= '9') {
            while (pos < input.len and std.ascii.isDigit(input[pos])) pos += 1;
        } else return error.InvalidNumber;

        if (pos < input.len and input[pos] == '.') {
            pos += 1;
            if (pos == input.len or !std.ascii.isDigit(input[pos])) return error.InvalidNumber;
            while (pos < input.len and std.ascii.isDigit(input[pos])) pos += 1;
        }

        if (pos < input.len and (input[pos] == 'e' or input[pos] == 'E')) {
            pos += 1;
            if (pos < input.len and (input[pos] == '+' or input[pos] == '-')) pos += 1;
            if (pos == input.len or !std.ascii.isDigit(input[pos])) return error.InvalidNumber;
            while (pos < input.len and std.ascii.isDigit(input[pos])) pos += 1;
        }
        self.pos = pos;
        return input[start..pos];
    }

    fn scanLiteral(self: *Cursor, comptime literal: []const u8, token: Token) Error!Token {
        if (self.pos + literal.len > self.input.len) return error.UnexpectedEof;
        if (!std.mem.eql(u8, self.input[self.pos..][0..literal.len], literal)) return error.UnexpectedToken;
        self.pos += literal.len;
        return token;
    }

    inline fn skipLiteral(self: *Cursor, comptime literal: []const u8) Error!void {
        if (self.pos + literal.len > self.input.len) return error.UnexpectedEof;
        if (!std.mem.eql(u8, self.input[self.pos..][0..literal.len], literal)) return error.UnexpectedToken;
        self.pos += literal.len;
    }

    pub fn skipWhitespace(self: *Cursor) void {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => return,
            }
        }
    }
    pub fn remainingBytes(self: *const Cursor) usize {
        return self.input.len - @min(self.pos, self.input.len);
    }
};

test "nested values" {
    var cursor: Cursor = .{ .input = "{\"a\":[1,true]}" };
    try std.testing.expectEqual(Token.object_begin, try cursor.next());
    try std.testing.expectEqualStrings("a", (try cursor.next()).string);
    try cursor.expectColon();
    try cursor.skipValue();
    try std.testing.expectEqual(Cursor.ContainerStep.end, try cursor.finishContainer('}'));
    try cursor.finish();
}
