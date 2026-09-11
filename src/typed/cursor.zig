const std = @import("std");
const float = @import("float");

/// The number of continuation bytes each first byte expects, or `0xFF` when it
/// cannot start a sequence.
const utf8_continuations: [256]u8 = blk: {
    var table: [256]u8 = @splat(0xFF);
    for (0x00..0x80) |i| table[i] = 0;
    for (0xC2..0xE0) |i| table[i] = 1;
    for (0xE0..0xF0) |i| table[i] = 2;
    for (0xF0..0xF5) |i| table[i] = 3;
    break :blk table;
};

/// The next JSON syntax item returned by `Cursor.next` or `Cursor.peek`.
///
/// The `string` and `number` payloads borrow the cursor input. A string payload
/// is still JSON-escaped; inspect `Cursor.last_string_has_escape` to determine
/// whether it needs unescaping.
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

/// Errors reported while tokenizing or structurally skipping JSON input.
pub const Error = error{
    UnexpectedToken,
    UnexpectedEof,
    InvalidNumber,
    InvalidEscape,
    InvalidControlCharacter,
    InvalidUtf8,
    MaxDepthExceeded,
};

/// A stateful, allocation-free cursor over one JSON document.
///
/// Methods advance `pos` when they succeed. The input slice must remain alive
/// while tokens or string/number payloads borrowed from it are in use.
pub const Cursor = struct {
    /// Complete JSON input being scanned.
    input: []const u8,
    /// Offset of the next byte to consume.
    pos: usize = 0,
    /// Number of currently open arrays and objects.
    depth: u32 = 0,
    /// Maximum allowed nesting depth.
    max_depth: u32 = 256,
    /// Whether the string returned by the most recent `next` contained `\\`.
    last_string_has_escape: bool = false,

    /// Consumes and returns the next JSON token, skipping leading whitespace.
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

    /// Returns the next token without advancing this cursor.
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

    /// Reports whether the next token is JSON `null`, without consuming it.
    ///
    /// Only the leading byte is inspected, which is all that distinguishing
    /// `null` needs. This keeps optional fields from scanning a whole string or
    /// number token only to throw the scan away.
    pub fn peekIsNull(self: *Cursor) Error!bool {
        self.skipWhitespace();
        if (self.pos == self.input.len) return error.UnexpectedEof;
        return self.input[self.pos] == 'n';
    }

    /// Consumes a required object key/value separator (`:`).
    pub fn expectColon(self: *Cursor) Error!void {
        self.skipWhitespace();
        if (self.pos == self.input.len) return error.UnexpectedEof;
        if (self.input[self.pos] != ':') return error.UnexpectedToken;
        self.pos += 1;
    }

    /// Reads an integer token as `T`, rejecting floats and values outside `T`.
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

    /// Reads the next JSON number as floating-point type `T`.
    ///
    /// The number is scanned and converted in a single pass; see `float/`.
    pub inline fn readFloat(self: *Cursor, comptime T: type) Error!T {
        self.skipWhitespace();
        const parsed = try float.parseNumber(T, self.input, self.pos);
        // JSON has no infinities, and the DOM rejects any number that does not
        // fit the target type, so an overflowing token is not valid here either.
        if (!std.math.isFinite(parsed.value)) return error.InvalidNumber;
        self.pos = parsed.end;
        return parsed.value;
    }

    /// The result of consuming a container separator or terminator.
    pub const ContainerStep = enum { end, more };

    /// Consumes either `end` or the comma before another container element.
    ///
    /// `end` must be the matching `}` or `]` for the currently open container.
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

    /// Reports whether the current container is immediately followed by `end`.
    /// This only inspects input; it does not consume the terminator.
    pub fn isContainerEmpty(self: *Cursor, end: u8) Error!bool {
        self.skipWhitespace();
        if (self.pos == self.input.len) return error.UnexpectedEof;
        return self.input[self.pos] == end;
    }

    /// Validates and skips one complete JSON value, including nested children.
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

    /// Verifies that only trailing JSON whitespace remains.
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
            const bytes: @Vector(4, u8) = input[pos..][0..4].*;
            const special =
                (bytes == @as(@Vector(4, u8), @splat('"'))) |
                (bytes == @as(@Vector(4, u8), @splat('\\'))) |
                (bytes < @as(@Vector(4, u8), @splat(0x20))) |
                (bytes >= @as(@Vector(4, u8), @splat(0x80)));
            if (@reduce(.Or, special)) break;
            pos += 4;
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
                else => pos = if (input[pos] < 0x80) pos + 1 else try skipUtf8(input, pos),
            }
        }
        return error.UnexpectedEof;
    }

    /// Advances over a run of UTF-8 sequences and returns the offset of the
    /// first ASCII byte.
    ///
    /// JSON text is UTF-8, so a lone continuation byte, an overlong form, a
    /// surrogate, or a code point past U+10FFFF is not a valid string. One
    /// little-endian 32-bit load validates a whole sequence, so runs move
    /// several bytes per iteration.
    fn skipUtf8(input: []const u8, start: usize) Error!usize {
        var pos = start;
        while (pos + 4 <= input.len) {
            const u = std.mem.readInt(u32, input[pos..][0..4], .little);
            // 3-byte sequence [1110xxxx 10xxxxxx 10xxxxxx].
            if (u & 0x00C0C0F0 == 0x008080E0) {
                const required = u & 0x0000200F;
                if (required == 0 or required == 0x0000200D) return error.InvalidUtf8;
                pos += 3;
                continue;
            }
            // 2-byte sequence [110xxxxx 10xxxxxx], rejecting overlong C0/C1.
            if (u & 0x0000C0E0 == 0x000080C0) {
                if (u & 0x0000001E == 0) return error.InvalidUtf8;
                pos += 2;
                continue;
            }
            // 4-byte sequence, restricted to U+10000..U+10FFFF.
            if (u & 0xC0C0C0F8 == 0x808080F0) {
                const required = u & 0x00003007;
                if (required == 0 or (required & 0x04 != 0 and required & 0x00003003 != 0)) return error.InvalidUtf8;
                pos += 4;
                continue;
            }
            if (u & 0x80 == 0) return pos;
            return error.InvalidUtf8;
        }
        // Fewer than four bytes remain: validate one sequence at a time.
        while (pos < input.len) {
            if (input[pos] < 0x80) return pos;
            pos += try utf8SequenceLen(input, pos);
        }
        return pos;
    }

    /// Validates one UTF-8 sequence at `pos` and returns its byte length.
    inline fn utf8SequenceLen(input: []const u8, pos: usize) Error!usize {
        const b0 = input[pos];
        const extra = utf8_continuations[b0];
        if (extra == 0xFF or pos + extra >= input.len) return error.InvalidUtf8;
        if (input[pos + 1] & 0xC0 != 0x80) return error.InvalidUtf8;
        if (extra == 1) return 2;
        if (input[pos + 2] & 0xC0 != 0x80) return error.InvalidUtf8;
        if (extra == 2) {
            const b1 = input[pos + 1];
            if (b0 == 0xE0 and b1 < 0xA0) return error.InvalidUtf8;
            if (b0 == 0xED and b1 >= 0xA0) return error.InvalidUtf8;
            return 3;
        }
        if (input[pos + 3] & 0xC0 != 0x80) return error.InvalidUtf8;
        const b1 = input[pos + 1];
        if (b0 == 0xF0 and b1 < 0x90) return error.InvalidUtf8;
        if (b0 == 0xF4 and b1 >= 0x90) return error.InvalidUtf8;
        return 4;
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

    /// Advances past JSON whitespace (` `, tab, LF, and CR).
    pub fn skipWhitespace(self: *Cursor) void {
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                else => return,
            }
        }
    }
    /// Returns the number of input bytes at or after the current position.
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
