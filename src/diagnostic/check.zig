//! The format checker behind `jsonz.diagnostic`.
//!
//! It reads a document's syntax on its own: no parser, no allocator, no schema.
//! Nothing is allocated, the input is never mutated, and it never recurses, so it
//! is safe on a borrowed buffer and on deeply nested input. Number tokens go
//! through `float.scanNumber`, and `classifyNumber` explains the ones it refuses.
//!
//! The module knows nothing about `jsonz.typed` or `jsonz.dom`.

const std = @import("std");
const float = @import("float");
const error_mod = @import("error.zig");

const CommentKind = error_mod.CommentKind;
const Diagnostic = error_mod.Diagnostic;
const EndContext = error_mod.EndContext;
const Literal = error_mod.Literal;
const Note = error_mod.Note;
const Problem = error_mod.Problem;
const Span = error_mod.Span;
const ValueHint = error_mod.ValueHint;

pub const CheckOptions = struct {
    allow_comments: bool = false,
    allow_trailing_commas: bool = false,
};

/// The deepest nesting the checker tracks exactly. Past it, structural
/// expectations are dropped rather than guessed at; lexical rules still apply.
pub const max_tracked_depth = 256;

/// Returns the first format problem in `input`, or `null` when it is valid JSON.
pub fn check(input: []const u8, options: CheckOptions) ?Diagnostic {
    var checker: Checker = .{ .input = input, .options = options };
    checker.run() catch |failure| switch (failure) {
        error.Invalid => return checker.diagnostic,
    };
    return null;
}

/// The error the checker uses to unwind to `check` once it has a diagnostic.
const Fail = error{Invalid};

const State = enum {
    root,
    trailing,
    array_value,
    array_end,
    object_key,
    object_value,
    object_end,
    done,
};

const Opener = struct {
    offset: usize,
    object: bool,
};

const Checker = struct {
    input: []const u8,
    options: CheckOptions,
    pos: usize = 0,
    depth: usize = 0,
    after_comma: bool = false,
    openers: [max_tracked_depth]Opener = undefined,
    diagnostic: Diagnostic = undefined,

    fn run(self: *Checker) Fail!void {
        if (self.input.len == 0) {
            return self.fail(Span.at(0), .empty_input);
        }
        if (std.mem.startsWith(u8, self.input, "\xEF\xBB\xBF")) {
            return self.fail(.{ .offset = 0, .len = 3 }, .unexpected_bom);
        }

        var state: State = .root;
        while (state != .done) {
            try self.skipTrivia();
            state = switch (state) {
                .root => try self.stepRoot(),
                .trailing => try self.stepTrailing(),
                .array_value => try self.stepArrayValue(),
                .array_end => try self.stepArrayEnd(),
                .object_key => try self.stepObjectKey(),
                .object_value => try self.stepObjectValue(),
                .object_end => try self.stepObjectEnd(),
                .done => unreachable,
            };
        }
    }

    fn stepRoot(self: *Checker) Fail!State {
        if (self.pos == self.input.len) {
            return self.fail(Span.at(self.pos), .{ .unexpected_end = .value });
        }
        if (try self.scanValue()) |container| return container;
        return .trailing;
    }

    fn stepTrailing(self: *Checker) Fail!State {
        if (self.pos != self.input.len) {
            return self.fail(
                .{ .offset = self.pos, .len = self.input.len - self.pos },
                .{ .trailing_data = self.input[self.pos] },
            );
        }
        return .done;
    }

    fn stepArrayValue(self: *Checker) Fail!State {
        if (self.pos == self.input.len) return self.failContainerEnd(.value);
        switch (self.input[self.pos]) {
            ']' => {
                self.pos += 1;
                return self.closeContainer();
            },
            '[' => return self.openContainer(false),
            '{' => return self.openContainer(true),
            else => {
                try self.scanScalar();
                return .array_end;
            },
        }
    }

    fn stepArrayEnd(self: *Checker) Fail!State {
        if (self.pos == self.input.len) return self.failContainerEnd(.array);
        switch (self.input[self.pos]) {
            ',' => {
                const comma = self.pos;
                self.pos += 1;
                try self.skipTrivia();
                if (self.pos < self.input.len and self.input[self.pos] == ']') {
                    if (!self.options.allow_trailing_commas) {
                        return self.fail(.{ .offset = comma, .len = 1 }, .trailing_comma_array);
                    }
                    self.pos += 1;
                    return self.closeContainer();
                }
                return .array_value;
            },
            ']' => {
                self.pos += 1;
                return self.closeContainer();
            },
            else => return self.fail(
                .{ .offset = self.pos, .len = 1 },
                .{ .expected_comma_or_array_end = self.input[self.pos] },
            ),
        }
    }

    fn stepObjectKey(self: *Checker) Fail!State {
        if (self.pos == self.input.len) {
            return self.failContainerEnd(if (self.after_comma) .key else .object);
        }
        switch (self.input[self.pos]) {
            '}' => {
                self.pos += 1;
                return self.closeContainer();
            },
            '"' => {
                try self.scanString();
                try self.skipTrivia();
                if (self.pos == self.input.len) return self.failContainerEnd(.colon);
                if (self.input[self.pos] != ':') {
                    return self.fail(
                        .{ .offset = self.pos, .len = 1 },
                        .{ .expected_colon = self.input[self.pos] },
                    );
                }
                self.pos += 1;
                self.after_comma = false;
                return .object_value;
            },
            else => return self.fail(
                .{ .offset = self.pos, .len = 1 },
                .{ .expected_key = self.input[self.pos] },
            ),
        }
    }

    fn stepObjectValue(self: *Checker) Fail!State {
        if (self.pos == self.input.len) return self.failContainerEnd(.value);
        if (try self.scanValue()) |container| return container;
        return .object_end;
    }

    fn stepObjectEnd(self: *Checker) Fail!State {
        if (self.pos == self.input.len) return self.failContainerEnd(.object);
        switch (self.input[self.pos]) {
            ',' => {
                const comma = self.pos;
                self.pos += 1;
                try self.skipTrivia();
                if (self.pos < self.input.len and self.input[self.pos] == '}') {
                    if (!self.options.allow_trailing_commas) {
                        return self.fail(.{ .offset = comma, .len = 1 }, .trailing_comma_object);
                    }
                    self.pos += 1;
                    return self.closeContainer();
                }
                self.after_comma = true;
                return .object_key;
            },
            '}' => {
                self.pos += 1;
                return self.closeContainer();
            },
            else => return self.fail(
                .{ .offset = self.pos, .len = 1 },
                .{ .expected_comma_or_object_end = self.input[self.pos] },
            ),
        }
    }

    /// Scans one value. Returns the state to continue in when a container was
    /// opened, or null when a scalar was scanned.
    fn scanValue(self: *Checker) Fail!?State {
        switch (self.input[self.pos]) {
            '[' => return try self.openContainer(false),
            '{' => return try self.openContainer(true),
            '"' => {
                try self.scanString();
                return null;
            },
            't', 'f', 'n' => {
                try self.scanLiteral();
                return null;
            },
            '+', '-', '.', '0'...'9' => {
                try self.scanNumber();
                return null;
            },
            else => return self.failValue(),
        }
    }

    fn scanScalar(self: *Checker) Fail!void {
        switch (self.input[self.pos]) {
            '"' => return self.scanString(),
            't', 'f', 'n' => return self.scanLiteral(),
            '+', '-', '.', '0'...'9' => return self.scanNumber(),
            else => return self.failValue(),
        }
    }

    fn openContainer(self: *Checker, object: bool) Fail!State {
        if (self.depth < max_tracked_depth) {
            self.openers[self.depth] = .{ .offset = self.pos, .object = object };
        }
        self.depth += 1;
        self.after_comma = false;
        self.pos += 1;
        if (self.depth > max_tracked_depth) {
            try self.scanUntracked();
            const parent = self.openers[max_tracked_depth - 1];
            return if (parent.object) .object_end else .array_end;
        }
        return if (object) .object_key else .array_value;
    }

    fn closeContainer(self: *Checker) State {
        self.depth -= 1;
        if (self.depth == 0) return .trailing;
        const parent = self.openers[self.depth - 1];
        return if (parent.object) .object_end else .array_end;
    }

    fn innermostOpener(self: *Checker) Opener {
        return self.openers[@min(self.depth, max_tracked_depth) - 1];
    }

    fn failContainerEnd(self: *Checker, context: EndContext) Fail {
        if (self.depth == 0) return self.fail(Span.at(self.pos), .{ .unexpected_end = context });
        const opener = self.innermostOpener();
        return self.failNote(Span.at(self.pos), .{ .unexpected_end = context }, .{
            .message = if (opener.object) "the object starts here" else "the array starts here",
            .span = .{ .offset = opener.offset, .len = 1 },
        });
    }

    /// Reports a byte that cannot start a value, classifying the "almost JSON"
    /// habits that produce most of them.
    fn failValue(self: *Checker) Fail {
        const hint = valueHint(self.input, self.pos);
        return self.fail(
            .{ .offset = self.pos, .len = valueSpanLength(self.input, self.pos, hint) },
            .{ .expected_value = hint },
        );
    }

    fn scanLiteral(self: *Checker) Fail!void {
        const rest = self.input[self.pos..];
        if (std.mem.startsWith(u8, rest, "true")) {
            self.pos += 4;
            return;
        }
        if (std.mem.startsWith(u8, rest, "false")) {
            self.pos += 5;
            return;
        }
        if (std.mem.startsWith(u8, rest, "null")) {
            self.pos += 4;
            return;
        }
        const literal: Literal = switch (self.input[self.pos]) {
            't' => .true_lit,
            'f' => .false_lit,
            else => .null_lit,
        };
        return self.fail(
            .{ .offset = self.pos, .len = wordLength(self.input, self.pos) },
            .{ .unknown_literal = literal },
        );
    }

    fn scanNumber(self: *Checker) Fail!void {
        const input = self.input;
        const start = self.pos;

        // The number scanner alone would only say "invalid number".
        if (std.mem.startsWith(u8, input[start..], "-Infinity") or
            std.mem.startsWith(u8, input[start..], "+Infinity"))
        {
            return self.fail(.{ .offset = start, .len = 9 }, .{ .expected_value = .nan_or_infinity });
        }

        const scanned = float.scanNumber(input, start) catch {
            const failure = classifyNumber(input, start);
            return self.fail(failure.span, .{ .invalid_number = failure.kind });
        };
        self.pos = scanned.end;

        // The scanner stops after the `0` of `01`, leaving `1` to the separator
        // check, so name what actually went wrong.
        const zero = if (input[start] == '-') start + 1 else start;
        if (input[zero] == '0' and self.pos < input.len) {
            if (std.ascii.isDigit(input[self.pos])) {
                return self.fail(.{ .offset = zero, .len = 1 }, .{ .invalid_number = .leading_zero });
            }
            // `0x` and `0b` come from other languages; naming them beats
            // "expected 'EOF', found 'x'".
            switch (input[self.pos]) {
                'x', 'X' => return self.fail(
                    .{ .offset = zero, .len = 2 },
                    .{ .expected_value = .hex_literal },
                ),
                'b', 'B' => return self.fail(
                    .{ .offset = zero, .len = 2 },
                    .{ .expected_value = .binary_literal },
                ),
                else => {},
            }
        }

        const value = float.convertScanned(f64, scanned) orelse
            (std.fmt.parseFloat(f64, input[start..scanned.end]) catch
                return self.fail(
                    .{ .offset = start, .len = scanned.end - start },
                    .{ .invalid_number = .missing_digits },
                ));
        if (!std.math.isFinite(value)) {
            return self.fail(.{ .offset = start, .len = scanned.end - start }, .number_out_of_range);
        }
    }

    fn scanString(self: *Checker) Fail!void {
        const open = self.pos;
        self.pos += 1;
        while (true) {
            if (self.pos == self.input.len) {
                return self.failNote(Span.at(self.pos), .{ .unexpected_end = .string }, .{
                    .message = "the string is never closed",
                    .span = .{ .offset = open, .len = 1 },
                });
            }
            const byte = self.input[self.pos];
            if (byte == '"') {
                self.pos += 1;
                return;
            }
            if (byte == '\\') {
                try self.scanEscape();
                continue;
            }
            if (byte < 0x20) {
                return self.fail(.{ .offset = self.pos, .len = 1 }, .{ .unescaped_control = byte });
            }
            if (byte < 0x80) {
                self.pos += 1;
                continue;
            }
            try self.scanUtf8();
        }
    }

    fn scanEscape(self: *Checker) Fail!void {
        const backslash = self.pos;
        self.pos += 1;
        if (self.pos == self.input.len) {
            return self.fail(Span.at(self.pos), .{ .unexpected_end = .escape });
        }
        const escape = self.input[self.pos];
        switch (escape) {
            '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => self.pos += 1,
            'u' => {
                self.pos += 1;
                try self.scanUnicodeEscape(backslash);
            },
            else => return self.fail(.{ .offset = backslash, .len = 2 }, .{ .invalid_escape = escape }),
        }
    }

    fn scanUnicodeEscape(self: *Checker, backslash: usize) Fail!void {
        const high = try self.readHex4(backslash);
        if (high >= 0xd800 and high <= 0xdbff) {
            const input = self.input;
            if (self.pos + 1 >= input.len or
                input[self.pos] != '\\' or input[self.pos + 1] != 'u')
            {
                return self.fail(
                    .{ .offset = backslash, .len = 6 },
                    .{ .invalid_unicode_escape = .lone_leading_surrogate },
                );
            }
            self.pos += 2;
            const low = try self.readHex4(backslash);
            if (low < 0xdc00 or low > 0xdfff) {
                return self.fail(
                    .{ .offset = backslash, .len = 6 },
                    .{ .invalid_unicode_escape = .lone_leading_surrogate },
                );
            }
            return;
        }
        if (high >= 0xdc00 and high <= 0xdfff) {
            return self.fail(
                .{ .offset = backslash, .len = 6 },
                .{ .invalid_unicode_escape = .lone_trailing_surrogate },
            );
        }
    }

    fn readHex4(self: *Checker, backslash: usize) Fail!u21 {
        var value: u21 = 0;
        var digits: u8 = 0;
        while (digits < 4) : (digits += 1) {
            if (self.pos == self.input.len) {
                return self.fail(Span.at(self.pos), .{ .unexpected_end = .unicode_escape });
            }
            const byte = self.input[self.pos];
            const digit = hexValue(byte) orelse {
                if (byte == '"' or byte < 0x20) {
                    return self.fail(
                        .{ .offset = backslash, .len = self.pos - backslash },
                        .{ .invalid_unicode_escape = .truncated },
                    );
                }
                return self.fail(
                    .{ .offset = self.pos, .len = 1 },
                    .{ .invalid_unicode_escape = .{ .invalid_hex_digit = byte } },
                );
            };
            value = (value << 4) | digit;
            self.pos += 1;
        }
        return value;
    }

    fn scanUtf8(self: *Checker) Fail!void {
        const input = self.input;
        const start = self.pos;
        const lead = input[start];

        if (lead == 0xc0 or lead == 0xc1) {
            return self.fail(
                .{ .offset = start, .len = @min(2, input.len - start) },
                .{ .invalid_utf8 = .overlong },
            );
        }
        if (lead >= 0xf5 and lead <= 0xf7) {
            return self.fail(.{ .offset = start, .len = 1 }, .{ .invalid_utf8 = .out_of_range });
        }
        if (lead >= 0xf8) {
            return self.fail(.{ .offset = start, .len = 1 }, .{ .invalid_utf8 = .invalid_lead });
        }
        const extra = utf8Continuations(lead);
        if (extra == 0xff) {
            return self.fail(.{ .offset = start, .len = 1 }, .{ .invalid_utf8 = .invalid_continuation });
        }
        if (start + extra >= input.len) {
            return self.fail(.{ .offset = start, .len = input.len - start }, .{ .invalid_utf8 = .truncated });
        }
        var index: usize = 1;
        while (index <= extra) : (index += 1) {
            if (input[start + index] & 0xc0 != 0x80) {
                return self.fail(
                    .{ .offset = start, .len = index + 1 },
                    .{ .invalid_utf8 = .invalid_continuation },
                );
            }
        }
        const second = input[start + 1];
        if (extra == 2) {
            if (lead == 0xe0 and second < 0xa0) {
                return self.fail(.{ .offset = start, .len = 3 }, .{ .invalid_utf8 = .overlong });
            }
            if (lead == 0xed and second >= 0xa0) {
                return self.fail(.{ .offset = start, .len = 3 }, .{ .invalid_utf8 = .surrogate });
            }
        } else if (extra == 3) {
            if (lead == 0xf0 and second < 0x90) {
                return self.fail(.{ .offset = start, .len = 4 }, .{ .invalid_utf8 = .overlong });
            }
            if (lead == 0xf4 and second >= 0x90) {
                return self.fail(.{ .offset = start, .len = 4 }, .{ .invalid_utf8 = .out_of_range });
            }
        }
        self.pos = start + extra + 1;
    }

    fn skipTrivia(self: *Checker) Fail!void {
        const input = self.input;
        while (self.pos < input.len) {
            switch (input[self.pos]) {
                ' ', '\t', '\n', '\r' => self.pos += 1,
                '/' => {
                    if (self.pos + 1 == input.len) return;
                    const kind: CommentKind = switch (input[self.pos + 1]) {
                        '/' => .line,
                        '*' => .block,
                        else => return,
                    };
                    if (!self.options.allow_comments) {
                        const len = if (kind == .line)
                            lineCommentLength(input, self.pos)
                        else blk: {
                            const block = blockCommentLength(input, self.pos);
                            break :blk if (block == 0) input.len - self.pos else block;
                        };
                        return self.fail(.{ .offset = self.pos, .len = len }, .{ .comments_not_allowed = kind });
                    }
                    try self.skipComment(kind);
                },
                else => return,
            }
        }
    }

    fn skipComment(self: *Checker, kind: CommentKind) Fail!void {
        const input = self.input;
        if (kind == .line) {
            self.pos += lineCommentLength(input, self.pos);
            return;
        }
        const len = blockCommentLength(input, self.pos);
        if (len == 0) {
            return self.fail(
                .{ .offset = self.pos, .len = input.len - self.pos },
                .unterminated_block_comment,
            );
        }
        self.pos += len;
    }

    /// Scans nesting deeper than `max_tracked_depth` lexically only: strings,
    /// numbers, escapes and comments must still be valid, but structure is dropped.
    fn scanUntracked(self: *Checker) Fail!void {
        while (self.depth > max_tracked_depth) {
            try self.skipTrivia();
            if (self.pos == self.input.len) return self.failContainerEnd(.value);
            switch (self.input[self.pos]) {
                '[', '{' => {
                    self.depth += 1;
                    self.pos += 1;
                },
                ']', '}' => {
                    self.depth -= 1;
                    self.pos += 1;
                },
                '"' => try self.scanString(),
                't', 'f', 'n' => try self.scanLiteral(),
                '+', '-', '.', '0'...'9' => try self.scanNumber(),
                ',', ':' => self.pos += 1,
                else => return self.failValue(),
            }
        }
    }

    fn fail(self: *Checker, span: Span, problem: Problem) Fail {
        return self.failNote(span, problem, null);
    }

    fn failNote(self: *Checker, span: Span, problem: Problem, note: ?Note) Fail {
        self.diagnostic = .{ .span = span, .problem = problem, .note = note };
        return error.Invalid;
    }
};

const NumberFailure = struct {
    kind: error_mod.NumberKind,
    span: Span,
};

/// Explains a number `float.scanNumber` refused, and looks one byte past the
/// token: the scanner accepts the `0` of `01` and leaves the `1` to the caller.
fn classifyNumber(input: []const u8, start: usize) NumberFailure {
    var pos = start;
    if (pos < input.len and input[pos] == '+') {
        return .{ .kind = .plus_sign, .span = .{ .offset = pos, .len = 1 } };
    }
    if (pos < input.len and input[pos] == '-') pos += 1;
    if (pos == input.len) {
        return .{ .kind = .missing_digits, .span = .{ .offset = start, .len = input.len - start } };
    }

    if (input[pos] == '0') {
        const zero = pos;
        pos += 1;
        if (pos < input.len and std.ascii.isDigit(input[pos])) {
            return .{ .kind = .leading_zero, .span = .{ .offset = zero, .len = 1 } };
        }
    } else if (std.ascii.isDigit(input[pos])) {
        while (pos < input.len and std.ascii.isDigit(input[pos])) pos += 1;
    } else if (input[pos] == '.') {
        return .{ .kind = .integer_digits, .span = .{ .offset = pos, .len = 1 } };
    } else {
        return .{ .kind = .missing_digits, .span = .{ .offset = pos, .len = 1 } };
    }

    if (pos < input.len and input[pos] == '.') {
        const point = pos;
        pos += 1;
        if (pos == input.len or !std.ascii.isDigit(input[pos])) {
            return .{ .kind = .fraction_digits, .span = .{ .offset = point, .len = 1 } };
        }
        while (pos < input.len and std.ascii.isDigit(input[pos])) pos += 1;
    }

    if (pos < input.len and (input[pos] == 'e' or input[pos] == 'E')) {
        const marker = pos;
        pos += 1;
        if (pos < input.len and (input[pos] == '+' or input[pos] == '-')) pos += 1;
        if (pos == input.len or !std.ascii.isDigit(input[pos])) {
            return .{ .kind = .exponent_digits, .span = .{ .offset = marker, .len = 1 } };
        }
        while (pos < input.len and std.ascii.isDigit(input[pos])) pos += 1;
    }

    return .{ .kind = .missing_digits, .span = .{ .offset = start, .len = pos - start } };
}

fn valueHint(input: []const u8, start: usize) ValueHint {
    const rest = input[start..];
    const byte = rest[0];
    if (byte == '\'') return .single_quote;
    if (std.mem.startsWith(u8, rest, "NaN") or
        std.mem.startsWith(u8, rest, "Infinity") or
        std.mem.startsWith(u8, rest, "-Infinity"))
    {
        return .nan_or_infinity;
    }
    if (std.mem.startsWith(u8, rest, "0x") or std.mem.startsWith(u8, rest, "0X")) return .hex_literal;
    if (std.mem.startsWith(u8, rest, "0b") or std.mem.startsWith(u8, rest, "0B")) return .binary_literal;
    if (isWrongCaseKeyword(input, start)) return .uppercase_literal;
    if (byte < 0x20) return .control_character;
    if (byte >= 0x80) return .non_ascii;
    return .none;
}

fn isWrongCaseKeyword(input: []const u8, start: usize) bool {
    const word = input[start..][0..wordLength(input, start)];
    for ([_][]const u8{ "true", "false", "null" }) |keyword| {
        if (std.ascii.eqlIgnoreCase(word, keyword) and !std.mem.eql(u8, word, keyword)) return true;
    }
    return false;
}

fn valueSpanLength(input: []const u8, start: usize, hint: ValueHint) usize {
    const rest = input[start..];
    return switch (hint) {
        .none, .single_quote, .control_character => 1,
        .nan_or_infinity => if (std.mem.startsWith(u8, rest, "Infinity")) 8 else 3,
        .hex_literal, .binary_literal => 2,
        .uppercase_literal => @max(wordLength(input, start), 1),
        .non_ascii => @min(utf8SpanLength(rest[0]), rest.len),
    };
}

fn utf8SpanLength(lead: u8) usize {
    return switch (lead) {
        0x00...0x7f => 1,
        0x80...0xbf => 1,
        0xc0...0xdf => 2,
        0xe0...0xef => 3,
        else => 4,
    };
}

fn wordLength(input: []const u8, start: usize) usize {
    var pos = start;
    while (pos < input.len and std.ascii.isAlphanumeric(input[pos])) pos += 1;
    return @max(pos - start, 1);
}

fn hexValue(byte: u8) ?u21 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        'A'...'F' => byte - 'A' + 10,
        else => null,
    };
}

/// Continuation-byte count for a UTF-8 lead byte, or `0xFF` when it cannot
/// start a sequence, or `0xFF` when it cannot start one.
fn utf8Continuations(byte: u8) u8 {
    return switch (byte) {
        0x00...0x7f => 0,
        0xc2...0xdf => 1,
        0xe0...0xef => 2,
        0xf0...0xf4 => 3,
        else => 0xff,
    };
}

fn lineCommentLength(input: []const u8, start: usize) usize {
    var pos = start;
    while (pos < input.len and input[pos] != '\n' and input[pos] != '\r') pos += 1;
    return pos - start;
}

/// Length of a `/* ... */` comment including the terminator, or 0 when unterminated.
fn blockCommentLength(input: []const u8, start: usize) usize {
    var pos = start + 2;
    while (pos + 1 < input.len) : (pos += 1) {
        if (input[pos] == '*' and input[pos + 1] == '/') return pos + 2 - start;
    }
    return 0;
}

const testing = std.testing;

fn expectDiagnostic(input: []const u8, options: CheckOptions, expected: Diagnostic) !void {
    const actual = check(input, options) orelse {
        std.debug.print("expected a diagnostic for {s}\n", .{input});
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(expected.span.offset, actual.span.offset);
    try testing.expectEqual(expected.span.len, actual.span.len);
    if (!std.meta.eql(expected.problem, actual.problem)) {
        std.debug.print("problem mismatch for {s}\n", .{input});
        return error.TestUnexpectedResult;
    }
    if (expected.note) |note| {
        const actual_note = actual.note orelse {
            std.debug.print("expected a note for {s}\n", .{input});
            return error.TestUnexpectedResult;
        };
        try testing.expectEqualStrings(note.message, actual_note.message);
        try testing.expectEqual(note.span == null, actual_note.span == null);
    }
}

fn expectValid(input: []const u8, options: CheckOptions) !void {
    if (check(input, options)) |diagnostic| {
        std.debug.print("unexpected {s} at {d} for {s}\n", .{
            @tagName(diagnostic.problem),
            diagnostic.span.offset,
            input,
        });
        return error.TestUnexpectedResult;
    }
}

test "valid documents" {
    const cases = [_][]const u8{
        "null",
        "true",
        "false",
        "0",
        "-0",
        "1",
        "-1",
        "1.5",
        "-1.5e10",
        "1E+2",
        "18446744073709551615",
        "\"\"",
        "\"jsonz\"",
        "\"\\u0041\\n\\t\\\\\"",
        "\"\\uD83D\\uDE00\"",
        "\"\xe4\xb8\xad\xe6\x96\x87\"",
        "[]",
        "{}",
        "[1,2,3]",
        "{\"a\":1,\"b\":[true,false,null],\"c\":{}}",
        "[[[[[[]]]]]]",
        " \t\r\n{\n  \"a\" : 1\n}\n",
    };
    for (cases) |case| try expectValid(case, .{});
}

test "empty and framing" {
    try expectDiagnostic("", .{}, Diagnostic.init(Span.at(0), .empty_input));
    try expectDiagnostic("   ", .{}, Diagnostic.init(Span.at(3), .{ .unexpected_end = .value }));
    try expectDiagnostic(
        "\xef\xbb\xbf{}",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 3 }, .unexpected_bom),
    );
    try expectDiagnostic(
        "1 x",
        .{},
        Diagnostic.init(.{ .offset = 2, .len = 1 }, .{ .trailing_data = 'x' }),
    );
    try expectDiagnostic(
        "{} []",
        .{},
        Diagnostic.init(.{ .offset = 3, .len = 2 }, .{ .trailing_data = '[' }),
    );
}

test "objects" {
    try expectDiagnostic(
        "{1:2}",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 1 }, .{ .expected_key = '1' }),
    );
    try expectDiagnostic(
        "{\"a\" 1}",
        .{},
        Diagnostic.init(.{ .offset = 5, .len = 1 }, .{ .expected_colon = '1' }),
    );
    try expectDiagnostic(
        "{\"a\":1 \"b\":2}",
        .{},
        Diagnostic.init(.{ .offset = 7, .len = 1 }, .{ .expected_comma_or_object_end = '"' }),
    );
}

test "arrays" {
    try expectDiagnostic(
        "[1 2]",
        .{},
        Diagnostic.init(.{ .offset = 3, .len = 1 }, .{ .expected_comma_or_array_end = '2' }),
    );
    try expectDiagnostic(
        "[1",
        .{},
        Diagnostic.init(Span.at(2), .{ .unexpected_end = .array }),
    );
    try expectDiagnostic(
        "[",
        .{},
        Diagnostic.init(Span.at(1), .{ .unexpected_end = .value }),
    );
    try expectDiagnostic(
        "[}",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 1 }, .{ .expected_value = .none }),
    );
}

test "trailing commas" {
    const array = "[1,]";
    try expectDiagnostic(array, .{}, Diagnostic.init(.{ .offset = 2, .len = 1 }, .trailing_comma_array));
    const object = "{\"a\":1,}";
    try expectDiagnostic(object, .{}, Diagnostic.init(.{ .offset = 6, .len = 1 }, .trailing_comma_object));
    try expectValid(array, .{ .allow_trailing_commas = true });
    try expectValid(object, .{ .allow_trailing_commas = true });
}

test "comments" {
    try expectDiagnostic(
        "// hi\n1",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 5 }, .{ .comments_not_allowed = .line }),
    );
    try expectDiagnostic(
        "/* hi */ 1",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 8 }, .{ .comments_not_allowed = .block }),
    );
    try expectDiagnostic(
        "/* hi",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 5 }, .{ .comments_not_allowed = .block }),
    );
    try expectValid("// hi\n1", .{ .allow_comments = true });
    try expectValid("/* hi */ {\"a\":/* c */1}", .{ .allow_comments = true });
    try expectDiagnostic(
        "/* hi",
        .{ .allow_comments = true },
        Diagnostic.init(.{ .offset = 0, .len = 5 }, .unterminated_block_comment),
    );
    try expectValid("1 // trailing", .{ .allow_comments = true });
}

test "strings" {
    try expectDiagnostic(
        "\"abc",
        .{},
        Diagnostic.init(Span.at(4), .{ .unexpected_end = .string }),
    );
    try expectDiagnostic(
        "\"a\\q\"",
        .{},
        Diagnostic.init(.{ .offset = 2, .len = 2 }, .{ .invalid_escape = 'q' }),
    );
    try expectDiagnostic(
        "\"a\nb\"",
        .{},
        Diagnostic.init(.{ .offset = 2, .len = 1 }, .{ .unescaped_control = '\n' }),
    );
    try expectDiagnostic(
        "\"a\x01b\"",
        .{},
        Diagnostic.init(.{ .offset = 2, .len = 1 }, .{ .unescaped_control = 0x01 }),
    );
    try expectDiagnostic(
        "\"a\\",
        .{},
        Diagnostic.init(Span.at(3), .{ .unexpected_end = .escape }),
    );
    try expectDiagnostic(
        "\"\\u12\"",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 4 }, .{ .invalid_unicode_escape = .truncated }),
    );
    try expectDiagnostic(
        "\"\\u12",
        .{},
        Diagnostic.init(Span.at(5), .{ .unexpected_end = .unicode_escape }),
    );
    try expectDiagnostic(
        "\"\\uZZZZ\"",
        .{},
        Diagnostic.init(.{ .offset = 3, .len = 1 }, .{ .invalid_unicode_escape = .{ .invalid_hex_digit = 'Z' } }),
    );
    try expectDiagnostic(
        "\"\\uD800\"",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 6 }, .{ .invalid_unicode_escape = .lone_leading_surrogate }),
    );
    try expectDiagnostic(
        "\"\\uD800\\u0041\"",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 6 }, .{ .invalid_unicode_escape = .lone_leading_surrogate }),
    );
    try expectDiagnostic(
        "\"\\uDC00\"",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 6 }, .{ .invalid_unicode_escape = .lone_trailing_surrogate }),
    );
    try expectValid("\"\\uD83D\\uDE00\"", .{});
    try expectValid("\"\\\"\\\\\\/\\b\\f\\n\\r\\t\"", .{});
}

test "utf8" {
    try expectDiagnostic(
        "\"\xc2",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 1 }, .{ .invalid_utf8 = .truncated }),
    );
    try expectDiagnostic(
        "\"\xc2\"",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 2 }, .{ .invalid_utf8 = .invalid_continuation }),
    );
    try expectDiagnostic(
        "\"\xc0\x80\"",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 2 }, .{ .invalid_utf8 = .overlong }),
    );
    try expectDiagnostic(
        "\"\xe0\x80\x80\"",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 3 }, .{ .invalid_utf8 = .overlong }),
    );
    try expectDiagnostic(
        "\"\xed\xa0\x80\"",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 3 }, .{ .invalid_utf8 = .surrogate }),
    );
    try expectDiagnostic(
        "\"\xf4\x90\x80\x80\"",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 4 }, .{ .invalid_utf8 = .out_of_range }),
    );
    try expectDiagnostic(
        "\"\xf5\x80\x80\x80\"",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 1 }, .{ .invalid_utf8 = .out_of_range }),
    );
    try expectDiagnostic(
        "\"\xff\"",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 1 }, .{ .invalid_utf8 = .invalid_lead }),
    );
    try expectDiagnostic(
        "\"\x80\"",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 1 }, .{ .invalid_utf8 = .invalid_continuation }),
    );
    try expectDiagnostic(
        "\"\xc3(\"",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 2 }, .{ .invalid_utf8 = .invalid_continuation }),
    );
    try expectValid("\"\xc3\xa9\"", .{});
    try expectValid("\"\xf0\x9f\x98\x80\"", .{});
}

test "numbers" {
    try expectDiagnostic("01", .{}, Diagnostic.init(.{ .offset = 0, .len = 1 }, .{ .invalid_number = .leading_zero }));
    try expectDiagnostic("-01", .{}, Diagnostic.init(.{ .offset = 1, .len = 1 }, .{ .invalid_number = .leading_zero }));
    try expectDiagnostic("[01]", .{}, Diagnostic.init(.{ .offset = 1, .len = 1 }, .{ .invalid_number = .leading_zero }));
    try expectDiagnostic(".5", .{}, Diagnostic.init(.{ .offset = 0, .len = 1 }, .{ .invalid_number = .integer_digits }));
    try expectDiagnostic("1.", .{}, Diagnostic.init(.{ .offset = 1, .len = 1 }, .{ .invalid_number = .fraction_digits }));
    try expectDiagnostic("1e", .{}, Diagnostic.init(.{ .offset = 1, .len = 1 }, .{ .invalid_number = .exponent_digits }));
    try expectDiagnostic("1e+", .{}, Diagnostic.init(.{ .offset = 1, .len = 1 }, .{ .invalid_number = .exponent_digits }));
    try expectDiagnostic("+1", .{}, Diagnostic.init(.{ .offset = 0, .len = 1 }, .{ .invalid_number = .plus_sign }));
    try expectDiagnostic("-", .{}, Diagnostic.init(.{ .offset = 0, .len = 1 }, .{ .invalid_number = .missing_digits }));
    try expectDiagnostic(
        "1e309",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 5 }, .number_out_of_range),
    );
    try expectDiagnostic(
        "-1e309",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 6 }, .number_out_of_range),
    );
    try expectValid("1e308", .{});
    try expectValid("-0.0", .{});
}

test "value hints" {
    try expectDiagnostic(
        "'text'",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 1 }, .{ .expected_value = .single_quote }),
    );
    try expectDiagnostic(
        "NaN",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 3 }, .{ .expected_value = .nan_or_infinity }),
    );
    try expectDiagnostic(
        "Infinity",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 8 }, .{ .expected_value = .nan_or_infinity }),
    );
    try expectDiagnostic(
        "-Infinity",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 9 }, .{ .expected_value = .nan_or_infinity }),
    );
    try expectDiagnostic(
        "0xFF",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 2 }, .{ .expected_value = .hex_literal }),
    );
    try expectDiagnostic(
        "0b1010",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 2 }, .{ .expected_value = .binary_literal }),
    );
    try expectDiagnostic(
        "TRUE",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 4 }, .{ .expected_value = .uppercase_literal }),
    );
    try expectDiagnostic(
        "Null",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 4 }, .{ .expected_value = .uppercase_literal }),
    );
    try expectDiagnostic(
        "\x07",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 1 }, .{ .expected_value = .control_character }),
    );
    try expectDiagnostic(
        "\xc3\xa9",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 2 }, .{ .expected_value = .non_ascii }),
    );
    try expectDiagnostic(
        "}",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 1 }, .{ .expected_value = .none }),
    );
    try expectDiagnostic(
        "[}",
        .{},
        Diagnostic.init(.{ .offset = 1, .len = 1 }, .{ .expected_value = .none }),
    );
}

test "unknown literals" {
    try expectDiagnostic(
        "tru",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 3 }, .{ .unknown_literal = .true_lit }),
    );
    try expectDiagnostic(
        "fals",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 4 }, .{ .unknown_literal = .false_lit }),
    );
    try expectDiagnostic(
        "nul",
        .{},
        Diagnostic.init(.{ .offset = 0, .len = 3 }, .{ .unknown_literal = .null_lit }),
    );
    try expectDiagnostic(
        "[truex]",
        .{},
        Diagnostic.init(.{ .offset = 5, .len = 1 }, .{ .expected_comma_or_array_end = 'x' }),
    );
}

test "end of input inside containers" {
    {
        const diagnostic = check("{\"a\": [1, 2", .{}).?;
        try testing.expectEqual(EndContext.array, diagnostic.problem.unexpected_end);
        try testing.expectEqual(@as(usize, 11), diagnostic.span.offset);
        const note = diagnostic.effectiveNote().?;
        try testing.expectEqualStrings("the array starts here", note.message);
        try testing.expectEqual(@as(usize, 6), note.span.?.offset);
        try testing.expectEqual(@as(usize, 1), note.span.?.len);
    }
    {
        const diagnostic = check("{\"a\": [1, ", .{}).?;
        try testing.expectEqual(EndContext.value, diagnostic.problem.unexpected_end);
        const note = diagnostic.effectiveNote().?;
        try testing.expectEqualStrings("the array starts here", note.message);
    }
    {
        const diagnostic = check("{\"a\": []", .{}).?;
        try testing.expectEqual(EndContext.object, diagnostic.problem.unexpected_end);
        try testing.expectEqualStrings("the object starts here", diagnostic.effectiveNote().?.message);
    }
    {
        const diagnostic = check("{\"a\": 1,", .{}).?;
        try testing.expectEqual(EndContext.key, diagnostic.problem.unexpected_end);
        const note = diagnostic.effectiveNote().?;
        try testing.expectEqualStrings("the object starts here", note.message);
        try testing.expectEqual(@as(usize, 0), note.span.?.offset);
    }
    {
        const diagnostic = check("{\"a\"", .{}).?;
        try testing.expectEqual(EndContext.colon, diagnostic.problem.unexpected_end);
    }
    {
        const diagnostic = check("{", .{}).?;
        try testing.expectEqual(EndContext.object, diagnostic.problem.unexpected_end);
        try testing.expectEqualStrings("the object starts here", diagnostic.effectiveNote().?.message);
    }
    {
        const diagnostic = check("[ \"abc", .{}).?;
        try testing.expectEqual(EndContext.string, diagnostic.problem.unexpected_end);
        const note = diagnostic.effectiveNote().?;
        try testing.expectEqualStrings("the string is never closed", note.message);
        try testing.expectEqual(@as(usize, 2), note.span.?.offset);
    }
}

test "contextual notes" {
    {
        const diagnostic = check("{\"a\":1,}", .{}).?;
        const note = diagnostic.effectiveNote().?;
        try testing.expectEqualStrings(
            "remove the trailing ','; JSON does not allow one, and .allow_trailing_commas = true accepts it",
            note.message,
        );
        try testing.expect(note.span == null);
    }
    {
        const diagnostic = check(".5", .{}).?;
        try testing.expectEqualStrings("write 0.5, not .5", diagnostic.effectiveNote().?.message);
    }
}

test "deep nesting" {
    const depth = 100_000;
    const allocator = testing.allocator;
    const input = try allocator.alloc(u8, depth * 2);
    defer allocator.free(input);
    @memset(input[0..depth], '[');
    @memset(input[depth..], ']');
    try expectValid(input, .{});

    input[depth * 2 - 1] = 'x';
    try testing.expect(check(input, .{}) != null);
}

test "untracked depth" {
    var input: [700]u8 = undefined;
    @memset(input[0..300], '[');
    @memset(input[300..400], '1');
    @memset(input[400..700], ']');
    if (check(input[0..700], .{})) |diagnostic| {
        std.debug.print("unexpected {s} at {d}\n", .{ @tagName(diagnostic.problem), diagnostic.span.offset });
        return error.TestUnexpectedResult;
    }

    var broken: [64]u8 = undefined;
    @memset(broken[0..40], '[');
    const tail = "\"a\\q\"";
    @memcpy(broken[40..][0..tail.len], tail);
    @memset(broken[40 + tail.len ..], ']');
    const diagnostic = check(&broken, .{}).?;
    try testing.expectEqual(@as(u8, 'q'), diagnostic.problem.invalid_escape);
    try testing.expectEqual(@as(usize, 42), diagnostic.span.offset);
}

test "input is not mutated" {
    var input = "{\"a\": \"\\u0041\", \"b\": [1,2,]}".*;
    const copy = input;
    _ = check(&input, .{});
    try testing.expectEqualStrings(&copy, &input);
}
