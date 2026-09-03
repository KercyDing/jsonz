const std = @import("std");

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
        defer {
            self.pos = pos;
            self.depth = depth;
        }
        return self.next();
    }

    pub fn expectColon(self: *Cursor) Error!void {
        self.skipWhitespace();
        if (self.pos == self.input.len) return error.UnexpectedEof;
        if (self.input[self.pos] != ':') return error.UnexpectedToken;
        self.pos += 1;
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
        switch (try self.next()) {
            .object_begin => {
                if (try self.consumeEmpty('}')) return;
                while (true) {
                    if (try self.next() != .string) return error.UnexpectedToken;
                    try self.expectColon();
                    try self.skipValue();
                    if (try self.finishContainer('}') == .end) return;
                }
            },
            .array_begin => {
                if (try self.consumeEmpty(']')) return;
                while (true) {
                    try self.skipValue();
                    if (try self.finishContainer(']') == .end) return;
                }
            },
            else => {},
        }
    }

    pub fn finish(self: *Cursor) Error!void {
        self.skipWhitespace();
        if (self.pos != self.input.len) return error.UnexpectedToken;
    }

    pub fn hasEscapes(value: []const u8) bool {
        return std.mem.findScalar(u8, value, '\\') != null;
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

    fn consumeEmpty(self: *Cursor, end: u8) Error!bool {
        if (!try self.isContainerEmpty(end)) return false;
        self.pos += 1;
        self.depth -= 1;
        return true;
    }

    fn scanString(self: *Cursor) Error![]const u8 {
        self.pos += 1;
        const start = self.pos;

        while (self.pos + 4 <= self.input.len) {
            const a = self.input[self.pos];
            const b = self.input[self.pos + 1];
            const c = self.input[self.pos + 2];
            const d = self.input[self.pos + 3];
            if ((a >= 0x20 and a != '"' and a != '\\') and
                (b >= 0x20 and b != '"' and b != '\\') and
                (c >= 0x20 and c != '"' and c != '\\') and
                (d >= 0x20 and d != '"' and d != '\\'))
            {
                self.pos += 4;
            } else break;
        }

        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                '"' => {
                    const value = self.input[start..self.pos];
                    self.pos += 1;
                    return value;
                },
                '\\' => {
                    self.pos += 1;
                    if (self.pos == self.input.len) return error.UnexpectedEof;
                    switch (self.input[self.pos]) {
                        '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => self.pos += 1,
                        'u' => {
                            if (self.pos + 5 > self.input.len) return error.UnexpectedEof;
                            for (self.input[self.pos + 1 .. self.pos + 5]) |digit| {
                                if (!std.ascii.isHex(digit)) return error.InvalidEscape;
                            }
                            self.pos += 5;
                        },
                        else => return error.InvalidEscape,
                    }
                },
                0x00...0x1f => return error.InvalidControlCharacter,
                else => self.pos += 1,
            }
        }
        return error.UnexpectedEof;
    }

    fn scanNumber(self: *Cursor) Error![]const u8 {
        const start = self.pos;
        if (self.input[self.pos] == '-') self.pos += 1;
        if (self.pos == self.input.len) return error.InvalidNumber;

        if (self.input[self.pos] == '0') {
            self.pos += 1;
        } else if (self.input[self.pos] >= '1' and self.input[self.pos] <= '9') {
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        } else return error.InvalidNumber;

        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            if (self.pos == self.input.len or !std.ascii.isDigit(self.input[self.pos])) return error.InvalidNumber;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        }

        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            self.pos += 1;
            if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-')) self.pos += 1;
            if (self.pos == self.input.len or !std.ascii.isDigit(self.input[self.pos])) return error.InvalidNumber;
            while (self.pos < self.input.len and std.ascii.isDigit(self.input[self.pos])) self.pos += 1;
        }
        return self.input[start..self.pos];
    }

    fn scanLiteral(self: *Cursor, comptime literal: []const u8, token: Token) Error!Token {
        if (self.pos + literal.len > self.input.len) return error.UnexpectedEof;
        if (!std.mem.eql(u8, self.input[self.pos..][0..literal.len], literal)) return error.UnexpectedToken;
        self.pos += literal.len;
        return token;
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
