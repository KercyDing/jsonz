//! The problem catalogue for `jsonz.diagnostic`: what went wrong with a JSON
//! document, and the evidence needed to explain it. Messages follow the Zig
//! compiler's phrasing: no trailing period, `'EOF'` for end of input.

const std = @import("std");

/// A byte range of the input. A `len` of zero marks a position at end of input.
pub const Span = struct {
    offset: usize,
    len: usize,

    pub fn at(offset: usize) Span {
        return .{ .offset = offset, .len = 0 };
    }
};

/// Extra context, rendered the way the Zig compiler renders `note:` blocks.
pub const Note = struct {
    /// Static text; anything document specific is derived from `span`.
    message: []const u8,
    /// When set, a second block with its own location; otherwise one line.
    span: ?Span = null,
};

/// The kind of value a failed literal was supposed to be.
pub const Literal = enum {
    true_lit,
    false_lit,
    null_lit,

    /// The keyword itself, for e.g. `expected 'true', found 'tru'`.
    pub fn text(self: Literal) []const u8 {
        return switch (self) {
            .true_lit => "true",
            .false_lit => "false",
            .null_lit => "null",
        };
    }
};

/// What the reader was in the middle of when the input ended.
pub const EndContext = enum { value, key, colon, string, escape, unicode_escape, array, object };

pub const CommentKind = enum { line, block };

/// Why a byte sequence is not valid UTF-8.
pub const Utf8Kind = enum {
    truncated,
    overlong,
    surrogate,
    out_of_range,
    invalid_continuation,
    invalid_lead,

    /// The phrase that follows `invalid UTF-8: `.
    pub fn text(self: Utf8Kind) []const u8 {
        return switch (self) {
            .truncated => "sequence is truncated",
            .overlong => "overlong encoding",
            .surrogate => "surrogate code point",
            .out_of_range => "code point above U+10FFFF",
            .invalid_continuation => "bad continuation byte",
            .invalid_lead => "invalid lead byte",
        };
    }
};

/// What is wrong with a `\u` escape.
pub const UnicodeEscape = union(enum) {
    truncated,
    invalid_hex_digit: u8,
    lone_leading_surrogate,
    lone_trailing_surrogate,
};

/// What is wrong with a number token.
pub const NumberKind = enum {
    /// A leading zero, as in `01`.
    leading_zero,
    /// No digit before the decimal point, as in `.5`.
    integer_digits,
    /// No digit after the decimal point, as in `1.`.
    fraction_digits,
    /// No digit in the exponent, as in `1e` or `1e+`.
    exponent_digits,
    /// A `+` sign, as in `+1`.
    plus_sign,
    /// Any other malformed number.
    missing_digits,

    /// The phrase that follows `invalid number: ` (or `invalid number`).
    pub fn text(self: NumberKind) []const u8 {
        return switch (self) {
            .leading_zero => "leading zeros are not allowed",
            .integer_digits => "expected a digit before the decimal point",
            .fraction_digits => "expected a digit after the decimal point",
            .exponent_digits => "expected a digit in the exponent",
            .plus_sign => "leading '+' is not allowed",
            .missing_digits => "",
        };
    }
};

/// A recognised "almost JSON" habit, which selects the note a failed value gets.
pub const ValueHint = enum {
    none,
    /// A single-quoted string, as in `'text'`.
    single_quote,
    /// `NaN`, `Infinity` or `-Infinity`.
    nan_or_infinity,
    /// A hex literal, as in `0xFF`.
    hex_literal,
    /// A binary literal, as in `0b1010`.
    binary_literal,
    /// A keyword in the wrong case, as in `TRUE`.
    uppercase_literal,
    /// A raw control byte outside a string.
    control_character,
    /// A non-ASCII byte outside a string.
    non_ascii,
};

/// One JSON format problem, with the evidence needed to explain it.
///
/// One tag per distinct fix. Payloads never hold slices: a multi-byte "found"
/// token lives in the primary span, and the message slices the input for it.
pub const Problem = union(enum) {
    empty_input,
    unexpected_bom,
    trailing_data: u8,
    expected_value: ValueHint,
    unexpected_end: EndContext,
    unknown_literal: Literal,
    expected_key: u8,
    expected_colon: u8,
    expected_comma_or_object_end: u8,
    expected_comma_or_array_end: u8,
    trailing_comma_object,
    trailing_comma_array,
    unterminated_string,
    invalid_escape: u8,
    unescaped_control: u8,
    invalid_utf8: Utf8Kind,
    invalid_unicode_escape: UnicodeEscape,
    invalid_number: NumberKind,
    /// A number that converts to infinity as a double.
    number_out_of_range,
    comments_not_allowed: CommentKind,
    unterminated_block_comment,

    /// The note this problem always carries, or null when the checker supplies one.
    pub fn note(self: Problem) ?[]const u8 {
        return switch (self) {
            .empty_input => "the input is empty",
            .unexpected_bom => "JSON does not allow a BOM; strip the leading EF BB BF bytes",
            .trailing_data => "JSON allows exactly one top-level value",
            .expected_value => |hint| switch (hint) {
                .none => null,
                .single_quote => "JSON strings use double quotes: \"text\"",
                .nan_or_infinity => "NaN and Infinity are not valid JSON; use null or a quoted string",
                .hex_literal => "JSON has no hex literals: write 255 instead of 0xFF",
                .binary_literal => "JSON has no binary literals",
                .uppercase_literal => "JSON keywords are lowercase: true, false, null",
                .control_character => "this byte has to be escaped",
                .non_ascii => "JSON values must be ASCII, or valid UTF-8 inside a string",
            },
            .unexpected_end => null,
            .unknown_literal => "JSON keywords are exactly 'true', 'false' and 'null'",
            .expected_key => "object property names must be double-quoted strings",
            .expected_colon => null,
            .expected_comma_or_object_end => null,
            .expected_comma_or_array_end => null,
            .trailing_comma_object,
            .trailing_comma_array,
            => "remove the trailing ','; JSON does not allow one, and .allow_trailing_commas = true accepts it",
            .unterminated_string => "add a closing '\"'",
            .invalid_escape => "valid escapes are \\\" \\\\ \\/ \\b \\f \\n \\r \\t and \\uXXXX",
            .unescaped_control => |byte| switch (byte) {
                '\n' => "write '\\n' instead of a literal newline",
                '\r' => "write '\\r' instead of a literal carriage return",
                '\t' => "write '\\t' instead of a literal tab",
                else => "escape it as \\u00XX",
            },
            .invalid_utf8 => |kind| switch (kind) {
                .overlong => "the code point must use its shortest form",
                .surrogate => "JSON escapes surrogates as '\\uXXXX' pairs",
                else => null,
            },
            .invalid_unicode_escape => |escape| switch (escape) {
                .truncated, .invalid_hex_digit => "a '\\u' escape needs exactly four hex digits",
                .lone_leading_surrogate => "a surrogate pair is a high surrogate followed by a low surrogate, e.g. '\\uD83D\\uDE00'",
                .lone_trailing_surrogate => "a low surrogate must follow a high surrogate",
            },
            .invalid_number => |kind| switch (kind) {
                .leading_zero => "write 1, not 01",
                .integer_digits => "write 0.5, not .5",
                .fraction_digits => "write 1.0, not 1.",
                .exponent_digits => null,
                .plus_sign => "JSON has no sign prefix; write 1, not +1",
                .missing_digits => null,
            },
            .number_out_of_range => "JSON numbers are read as i64, u64 or f64; this one converts to infinity",
            .comments_not_allowed => "remove the comment; JSON does not allow comments, and .allow_comments = true accepts them",
            .unterminated_block_comment => "add a closing '*/'",
        };
    }
};

/// One JSON format problem and where it is.
pub const Diagnostic = struct {
    span: Span,
    problem: Problem,
    /// Context the problem cannot express itself, such as an unclosed container.
    note: ?Note = null,

    pub fn init(span: Span, problem: Problem) Diagnostic {
        return .{ .span = span, .problem = problem };
    }

    /// The note to render: the contextual one when set, the problem's own otherwise.
    pub fn effectiveNote(self: Diagnostic) ?Note {
        if (self.note) |note| return note;
        const message = self.problem.note() orelse return null;
        return .{ .message = message };
    }

    /// Writes the header message, e.g. `expected ',' or ']', found '2'`.
    pub fn writeMessage(
        self: Diagnostic,
        input: []const u8,
        writer: *std.Io.Writer,
    ) std.Io.Writer.Error!void {
        switch (self.problem) {
            .empty_input => try writer.writeAll("expected a JSON value, found 'EOF'"),
            .unexpected_bom => try writer.writeAll("unexpected byte-order mark"),
            .trailing_data => |byte| {
                try writer.writeAll("expected 'EOF', found ");
                try writeCharLiteral(writer, byte);
            },
            .expected_value => |hint| switch (hint) {
                .none, .control_character => {
                    try writer.writeAll("expected a JSON value, found ");
                    try writeCharLiteral(writer, self.firstByte(input));
                },
                .single_quote => try writer.writeAll("expected a JSON value, found '\\''"),
                .nan_or_infinity, .hex_literal, .binary_literal, .uppercase_literal => {
                    try writer.writeAll("expected a JSON value, found '");
                    try writer.writeAll(self.text(input));
                    try writer.writeByte('\'');
                },
                .non_ascii => try writer.writeAll("expected a JSON value, found invalid bytes"),
            },
            .unexpected_end => |context| switch (context) {
                .value => try writer.writeAll("expected a JSON value, found 'EOF'"),
                .key => try writer.writeAll("expected a property name, found 'EOF'"),
                .colon => try writer.writeAll("expected ':', found 'EOF'"),
                .string => try writer.writeAll("expected '\"', found 'EOF'"),
                .escape => try writer.writeAll("expected an escape character, found 'EOF'"),
                .unicode_escape => try writer.writeAll("expected a hex digit, found 'EOF'"),
                .array => try writer.writeAll("expected ']', found 'EOF'"),
                .object => try writer.writeAll("expected '}', found 'EOF'"),
            },
            .unknown_literal => |literal| {
                try writer.print("expected '{s}', found '{s}'", .{ literal.text(), self.text(input) });
            },
            .expected_key => |byte| {
                try writer.writeAll("expected a property name, found ");
                try writeCharLiteral(writer, byte);
            },
            .expected_colon => |byte| {
                try writer.writeAll("expected ':', found ");
                try writeCharLiteral(writer, byte);
            },
            .expected_comma_or_object_end => |byte| {
                try writer.writeAll("expected ',' or '}', found ");
                try writeCharLiteral(writer, byte);
            },
            .expected_comma_or_array_end => |byte| {
                try writer.writeAll("expected ',' or ']', found ");
                try writeCharLiteral(writer, byte);
            },
            .trailing_comma_object, .trailing_comma_array => try writer.writeAll("trailing comma is not allowed"),
            .unterminated_string => try writer.writeAll("unterminated string"),
            .invalid_escape => |byte| {
                try writer.writeAll("invalid escape character: ");
                try writeCharLiteral(writer, byte);
            },
            .unescaped_control => |byte| {
                try writer.writeAll("string literal contains invalid byte: ");
                try writeCharLiteral(writer, byte);
            },
            .invalid_utf8 => |kind| try writer.print("invalid UTF-8: {s}", .{kind.text()}),
            .invalid_unicode_escape => |escape| switch (escape) {
                .truncated => try writer.writeAll("incomplete '\\u' escape"),
                .invalid_hex_digit => |byte| {
                    try writer.writeAll("invalid hex digit ");
                    try writeCharLiteral(writer, byte);
                    try writer.writeAll(" in '\\u' escape");
                },
                .lone_leading_surrogate => try writer.print("lone leading surrogate '{s}'", .{self.text(input)}),
                .lone_trailing_surrogate => try writer.print("lone trailing surrogate '{s}'", .{self.text(input)}),
            },
            .invalid_number => |kind| switch (kind) {
                .missing_digits => try writer.writeAll("invalid number"),
                else => try writer.print("invalid number: {s}", .{kind.text()}),
            },
            .number_out_of_range => try writer.writeAll("number is out of range for a double"),
            .comments_not_allowed => try writer.writeAll("comments are not allowed"),
            .unterminated_block_comment => try writer.writeAll("unterminated block comment"),
        }
    }

    /// 1-based line number of the primary span.
    pub fn line(self: Diagnostic, input: []const u8) usize {
        return locate(input, self.span.offset).line;
    }

    /// 1-based byte column of the primary span, matching the Zig compiler.
    pub fn column(self: Diagnostic, input: []const u8) usize {
        return locate(input, self.span.offset).column;
    }

    /// The bytes the primary span covers, clamped to the input.
    pub fn text(self: Diagnostic, input: []const u8) []const u8 {
        const end = @min(self.span.offset +| self.span.len, input.len);
        const start = @min(self.span.offset, end);
        return input[start..end];
    }

    /// The first byte of the primary span, or zero when it points past the input.
    pub fn firstByte(self: Diagnostic, input: []const u8) u8 {
        if (self.span.offset >= input.len) return 0;
        return input[self.span.offset];
    }
};

/// Where an offset sits in the input.
pub const Location = struct {
    /// 1-based.
    line: usize,
    /// 1-based byte column.
    column: usize,
    /// Offset of the first byte of the line.
    line_start: usize,
    /// Offset of the line's terminating newline, or of end of input.
    line_end: usize,
};

/// Locates `offset` in `input` in one pass.
pub fn locate(input: []const u8, offset: usize) Location {
    const clamped = @min(offset, input.len);
    var line: usize = 1;
    var line_start: usize = 0;
    for (input[0..clamped], 0..) |byte, index| {
        if (byte == '\n') {
            line += 1;
            line_start = index + 1;
        }
    }
    var line_end = clamped;
    while (line_end < input.len and input[line_end] != '\n') line_end += 1;
    return .{
        .line = line,
        .column = clamped - line_start + 1,
        .line_start = line_start,
        .line_end = line_end,
    };
}

/// Writes `byte` the way Zig renders a character literal: `'a'`, `'\n'`, `'\x07'`.
pub fn writeCharLiteral(writer: *std.Io.Writer, byte: u8) std.Io.Writer.Error!void {
    try writer.writeByte('\'');
    switch (byte) {
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        '\\' => try writer.writeAll("\\\\"),
        '\'' => try writer.writeAll("\\'"),
        0x20...0x26, 0x28...0x5b, 0x5d...0x7e => try writer.writeByte(byte),
        else => try writer.print("\\x{x:0>2}", .{byte}),
    }
    try writer.writeByte('\'');
}

const testing = std.testing;

fn expectMessage(problem: Problem, span: Span, input: []const u8, expected: []const u8) !void {
    var writer: std.Io.Writer.Allocating = .init(testing.allocator);
    defer writer.deinit();
    try (Diagnostic{ .span = span, .problem = problem }).writeMessage(input, &writer.writer);
    try testing.expectEqualStrings(expected, writer.written());
}

test "messages" {
    try expectMessage(.empty_input, Span.at(0), "", "expected a JSON value, found 'EOF'");
    try expectMessage(.unexpected_bom, .{ .offset = 0, .len = 3 }, "\xef\xbb\xbf", "unexpected byte-order mark");
    try expectMessage(.{ .trailing_data = 'x' }, .{ .offset = 5, .len = 1 }, "1    x", "expected 'EOF', found 'x'");
    try expectMessage(.{ .trailing_data = 0x0a }, .{ .offset = 5, .len = 1 }, "1    \n", "expected 'EOF', found '\\n'");
    try expectMessage(.{ .trailing_data = 0x07 }, .{ .offset = 5, .len = 1 }, "1    \x07", "expected 'EOF', found '\\x07'");

    try expectMessage(.{ .expected_value = .none }, .{ .offset = 0, .len = 1 }, "}", "expected a JSON value, found '}'");
    try expectMessage(.{ .expected_value = .single_quote }, .{ .offset = 0, .len = 1 }, "'a'", "expected a JSON value, found '\\''");
    try expectMessage(.{ .expected_value = .nan_or_infinity }, .{ .offset = 0, .len = 3 }, "NaN", "expected a JSON value, found 'NaN'");
    try expectMessage(.{ .expected_value = .hex_literal }, .{ .offset = 0, .len = 2 }, "0xFF", "expected a JSON value, found '0x'");
    try expectMessage(.{ .expected_value = .binary_literal }, .{ .offset = 0, .len = 2 }, "0b1", "expected a JSON value, found '0b'");
    try expectMessage(.{ .expected_value = .uppercase_literal }, .{ .offset = 0, .len = 4 }, "TRUE", "expected a JSON value, found 'TRUE'");
    try expectMessage(.{ .expected_value = .control_character }, .{ .offset = 0, .len = 1 }, "\x07", "expected a JSON value, found '\\x07'");
    try expectMessage(.{ .expected_value = .non_ascii }, .{ .offset = 0, .len = 2 }, "\xc3\xa9", "expected a JSON value, found invalid bytes");

    try expectMessage(.{ .unexpected_end = .value }, Span.at(3), "[\"a", "expected a JSON value, found 'EOF'");
    try expectMessage(.{ .unexpected_end = .key }, Span.at(5), "{\"a\":", "expected a property name, found 'EOF'");
    try expectMessage(.{ .unexpected_end = .string }, Span.at(4), "\"abc", "expected '\"', found 'EOF'");
    try expectMessage(.{ .unexpected_end = .escape }, Span.at(4), "\"a\\", "expected an escape character, found 'EOF'");
    try expectMessage(.{ .unexpected_end = .unicode_escape }, Span.at(6), "\"a\\u1", "expected a hex digit, found 'EOF'");
    try expectMessage(.{ .unexpected_end = .array }, .{ .offset = 0, .len = 1 }, "[1", "expected ']', found 'EOF'");
    try expectMessage(.{ .unexpected_end = .object }, .{ .offset = 0, .len = 1 }, "{\"a\":1", "expected '}', found 'EOF'");

    try expectMessage(.{ .unknown_literal = .true_lit }, .{ .offset = 0, .len = 3 }, "tru", "expected 'true', found 'tru'");
    try expectMessage(.{ .unknown_literal = .false_lit }, .{ .offset = 0, .len = 4 }, "fals", "expected 'false', found 'fals'");
    try expectMessage(.{ .unknown_literal = .null_lit }, .{ .offset = 0, .len = 3 }, "nul", "expected 'null', found 'nul'");

    try expectMessage(.{ .expected_key = '1' }, .{ .offset = 0, .len = 1 }, "1", "expected a property name, found '1'");
    try expectMessage(.{ .expected_colon = '}' }, .{ .offset = 0, .len = 1 }, "}", "expected ':', found '}'");
    try expectMessage(.{ .expected_comma_or_object_end = '2' }, .{ .offset = 0, .len = 1 }, "2", "expected ',' or '}', found '2'");
    try expectMessage(.{ .expected_comma_or_array_end = '2' }, .{ .offset = 0, .len = 1 }, "2", "expected ',' or ']', found '2'");
    try expectMessage(.trailing_comma_object, .{ .offset = 0, .len = 1 }, ",", "trailing comma is not allowed");
    try expectMessage(.trailing_comma_array, .{ .offset = 0, .len = 1 }, ",", "trailing comma is not allowed");

    try expectMessage(.unterminated_string, .{ .offset = 0, .len = 1 }, "\"abc", "unterminated string");
    try expectMessage(.{ .invalid_escape = 'q' }, .{ .offset = 0, .len = 2 }, "\\q", "invalid escape character: 'q'");
    try expectMessage(.{ .unescaped_control = '\n' }, .{ .offset = 0, .len = 1 }, "\n", "string literal contains invalid byte: '\\n'");

    try expectMessage(.{ .invalid_utf8 = .truncated }, .{ .offset = 0, .len = 1 }, "\xc2", "invalid UTF-8: sequence is truncated");
    try expectMessage(.{ .invalid_utf8 = .overlong }, .{ .offset = 0, .len = 2 }, "\xc0\x80", "invalid UTF-8: overlong encoding");
    try expectMessage(.{ .invalid_utf8 = .surrogate }, .{ .offset = 0, .len = 3 }, "\xed\xa0\x80", "invalid UTF-8: surrogate code point");
    try expectMessage(.{ .invalid_utf8 = .out_of_range }, .{ .offset = 0, .len = 4 }, "\xf4\x90\x80\x80", "invalid UTF-8: code point above U+10FFFF");
    try expectMessage(.{ .invalid_utf8 = .invalid_continuation }, .{ .offset = 0, .len = 2 }, "\xc3\x28", "invalid UTF-8: bad continuation byte");
    try expectMessage(.{ .invalid_utf8 = .invalid_lead }, .{ .offset = 0, .len = 1 }, "\xf8", "invalid UTF-8: invalid lead byte");

    try expectMessage(.{ .invalid_unicode_escape = .truncated }, .{ .offset = 0, .len = 4 }, "\\u12", "incomplete '\\u' escape");
    try expectMessage(.{ .invalid_unicode_escape = .{ .invalid_hex_digit = 'Z' } }, .{ .offset = 0, .len = 1 }, "Z", "invalid hex digit 'Z' in '\\u' escape");
    try expectMessage(.{ .invalid_unicode_escape = .lone_leading_surrogate }, .{ .offset = 0, .len = 6 }, "\\uD800", "lone leading surrogate '\\uD800'");
    try expectMessage(.{ .invalid_unicode_escape = .lone_trailing_surrogate }, .{ .offset = 0, .len = 6 }, "\\uDC00", "lone trailing surrogate '\\uDC00'");

    try expectMessage(.{ .invalid_number = .leading_zero }, .{ .offset = 0, .len = 1 }, "01", "invalid number: leading zeros are not allowed");
    try expectMessage(.{ .invalid_number = .integer_digits }, .{ .offset = 0, .len = 1 }, ".5", "invalid number: expected a digit before the decimal point");
    try expectMessage(.{ .invalid_number = .fraction_digits }, .{ .offset = 0, .len = 1 }, "1.", "invalid number: expected a digit after the decimal point");
    try expectMessage(.{ .invalid_number = .exponent_digits }, .{ .offset = 0, .len = 1 }, "1e", "invalid number: expected a digit in the exponent");
    try expectMessage(.{ .invalid_number = .plus_sign }, .{ .offset = 0, .len = 1 }, "+1", "invalid number: leading '+' is not allowed");
    try expectMessage(.{ .invalid_number = .missing_digits }, .{ .offset = 0, .len = 1 }, "-", "invalid number");

    try expectMessage(.number_out_of_range, .{ .offset = 0, .len = 5 }, "1e309", "number is out of range for a double");
    try expectMessage(.{ .comments_not_allowed = .line }, .{ .offset = 0, .len = 5 }, "// hi", "comments are not allowed");
    try expectMessage(.{ .comments_not_allowed = .block }, .{ .offset = 0, .len = 6 }, "/* hi */", "comments are not allowed");
    try expectMessage(.unterminated_block_comment, .{ .offset = 0, .len = 2 }, "/* hi", "unterminated block comment");
}

test "default notes" {
    const cases = [_]struct { problem: Problem, note: ?[]const u8 }{
        .{ .problem = .empty_input, .note = "the input is empty" },
        .{ .problem = .{ .expected_value = .single_quote }, .note = "JSON strings use double quotes: \"text\"" },
        .{ .problem = .{ .expected_value = .nan_or_infinity }, .note = "NaN and Infinity are not valid JSON; use null or a quoted string" },
        .{ .problem = .{ .expected_value = .hex_literal }, .note = "JSON has no hex literals: write 255 instead of 0xFF" },
        .{ .problem = .{ .expected_value = .uppercase_literal }, .note = "JSON keywords are lowercase: true, false, null" },
        .{ .problem = .{ .expected_value = .none }, .note = null },
        .{ .problem = .{ .unexpected_end = .array }, .note = null },
        .{ .problem = .{ .unescaped_control = '\n' }, .note = "write '\\n' instead of a literal newline" },
        .{ .problem = .{ .unescaped_control = 0x07 }, .note = "escape it as \\u00XX" },
        .{ .problem = .{ .invalid_utf8 = .overlong }, .note = "the code point must use its shortest form" },
        .{ .problem = .{ .invalid_utf8 = .truncated }, .note = null },
        .{ .problem = .{ .invalid_unicode_escape = .lone_leading_surrogate }, .note = "a surrogate pair is a high surrogate followed by a low surrogate, e.g. '\\uD83D\\uDE00'" },
        .{ .problem = .{ .invalid_number = .leading_zero }, .note = "write 1, not 01" },
        .{ .problem = .{ .invalid_number = .exponent_digits }, .note = null },
        .{ .problem = .trailing_comma_array, .note = "remove the trailing ','; JSON does not allow one, and .allow_trailing_commas = true accepts it" },
    };
    for (cases) |case| {
        const note = case.problem.note();
        if (case.note) |expected| {
            try testing.expectEqualStrings(expected, note.?);
        } else {
            try testing.expect(note == null);
        }
    }

    const contextual = Diagnostic{
        .span = .{ .offset = 0, .len = 1 },
        .problem = .{ .unexpected_end = .array },
        .note = .{ .message = "the array starts here", .span = .{ .offset = 0, .len = 1 } },
    };
    try testing.expectEqualStrings("the array starts here", contextual.effectiveNote().?.message);

    const plain = Diagnostic.init(.{ .offset = 0, .len = 1 }, .empty_input);
    try testing.expectEqualStrings("the input is empty", plain.effectiveNote().?.message);
    try testing.expect(plain.effectiveNote().?.span == null);
}

test "location" {
    const input = "{\n  \"a\": 1,\n  \"b\": 2\n}";
    const first = locate(input, 0);
    try testing.expectEqual(@as(usize, 1), first.line);
    try testing.expectEqual(@as(usize, 1), first.column);
    try testing.expectEqual(@as(usize, 0), first.line_start);
    try testing.expectEqual(@as(usize, 1), first.line_end);

    const second = locate(input, 3);
    try testing.expectEqual(@as(usize, 2), second.line);
    try testing.expectEqual(@as(usize, 2), second.column);
    try testing.expectEqual(@as(usize, 2), second.line_start);
    try testing.expectEqual(@as(usize, 11), second.line_end);

    const end = locate(input, input.len);
    try testing.expectEqual(@as(usize, 4), end.line);
    try testing.expectEqual(@as(usize, 2), end.column);

    const trailing_newline = locate("a\n", 2);
    try testing.expectEqual(@as(usize, 2), trailing_newline.line);
    try testing.expectEqual(@as(usize, 1), trailing_newline.column);

    const diagnostic = Diagnostic.init(.{ .offset = 4, .len = 1 }, .unterminated_string);
    try testing.expectEqual(@as(usize, 2), diagnostic.line(input));
    try testing.expectEqual(@as(usize, 3), diagnostic.column(input));
    try testing.expectEqualStrings("\"", diagnostic.text(input));
}
