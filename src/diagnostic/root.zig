//! JSON format diagnosis: what is wrong with a JSON document, where, and why.
//!
//! ```zig
//! // Silent when the input is valid:
//! try jsonz.diagnostic.print(input, .{ .source_name = "config.json" });
//!
//! // Or the text, or just a bool, or the diagnostic itself:
//! const message = try jsonz.diagnostic.toSlice(allocator, input, .{});
//! if (!jsonz.diagnostic.isValid(input, .{})) return error.InvalidJson;
//! if (jsonz.diagnostic.diagnose(input, .{})) |diagnostic| { ... }
//! ```
//!
//! Nothing here needs a parser, a schema, or a mutable input. `print` and
//! `printWith` stream the report; `toSlice` materialises it. The integration
//! tests at the bottom hold the verdict to `jsonz.dom`'s.

const std = @import("std");

const check_mod = @import("check.zig");
const error_mod = @import("error.zig");
const render_mod = @import("render.zig");

/// A byte range of the input.
pub const Span = error_mod.Span;
/// Extra context, rendered as a Zig-style `note:` block.
pub const Note = error_mod.Note;
/// Everything that can be wrong with a document's format.
pub const Problem = error_mod.Problem;
/// One format problem and where it is.
pub const Diagnostic = error_mod.Diagnostic;

/// Options for `isValid` and `diagnose`: what counts as valid JSON.
pub const Options = struct {
    /// Accept `//` and `/* ... */` comments, which are not part of standard JSON.
    allow_comments: bool = false,
    /// Accept a comma before a closing `]` or `}`, which is not part of standard JSON.
    allow_trailing_commas: bool = false,

    fn checkOptions(self: Options) check_mod.CheckOptions {
        return .{
            .allow_comments = self.allow_comments,
            .allow_trailing_commas = self.allow_trailing_commas,
        };
    }
};

/// Options for `print`, `printWith` and `toSlice`: how the report looks.
///
/// There is no colour flag: `print` asks standard error, and `printWith` writes
/// to the `std.Io.Terminal` the caller hands it, so the destination's own mode
/// decides. `toSlice` returns plain text.
pub const ReportOptions = struct {
    /// What counts as valid JSON for this document, so that a document read
    /// with extensions enabled is not reported as broken.
    check: Options = .{},
    /// Name shown in the header, e.g. `config.json:3:18: error: …`.
    source_name: []const u8 = "<input>",
    /// Source lines shown above and below the problem; 0 shows only that line.
    context_lines: u8 = 3,
    /// Cut a source line wider than this around the problem; 0 shows all of it.
    max_line_width: usize = 200,

    fn renderOptions(self: ReportOptions) render_mod.RenderOptions {
        return .{
            .source_name = self.source_name,
            .context_lines = self.context_lines,
            .max_line_width = self.max_line_width,
        };
    }
};

/// Returns the first format problem in `input`, or null when it is valid JSON.
/// The low-level entry point: the other four functions are built on it.
pub fn diagnose(input: []const u8, options: Options) ?Diagnostic {
    return check_mod.check(input, options.checkOptions());
}

/// Returns whether `input` is valid JSON.
pub fn isValid(input: []const u8, options: Options) bool {
    return diagnose(input, options) == null;
}

/// Writes the first format problem in `input` to standard error, and nothing
/// when the input is valid. It locks standard error for the caller, and colours
/// the report whenever that stream is a terminal that takes escape codes,
/// honouring `NO_COLOR` and `CLICOLOR_FORCE`.
pub fn print(input: []const u8, options: ReportOptions) std.Io.Writer.Error!void {
    var buffer: [1024]u8 = undefined;
    const stderr = std.debug.lockStderr(&buffer);
    defer std.debug.unlockStderr();
    try printWith(input, options, stderr.terminal());
}

/// Writes the report to `terminal`, and nothing when the input is valid JSON.
/// The report is streamed, so nothing is allocated and its size is unbounded.
///
/// Build the terminal from the destination, e.g.
/// `file.writer(io, &buffer).terminal()` or `.{ .writer = w, .mode = .no_color }`.
pub fn printWith(
    input: []const u8,
    options: ReportOptions,
    terminal: std.Io.Terminal,
) std.Io.Writer.Error!void {
    const diagnostic = diagnose(input, options.check) orelse return;
    return render_mod.render(diagnostic, input, terminal, options.renderOptions());
}

/// Renders the report into a slice owned by `allocator`, or returns null when
/// the input is valid JSON. The text is plain: escapes are left to whoever
/// prints it.
pub fn toSlice(allocator: std.mem.Allocator, input: []const u8, options: ReportOptions) !?[]const u8 {
    const diagnostic = diagnose(input, options.check) orelse return null;
    return try render_mod.toSlice(allocator, diagnostic, input, options.renderOptions());
}

test {
    _ = check_mod;
    _ = error_mod;
    _ = render_mod;
}

test "streaming and slicing agree" {
    // A report bigger than any reasonable buffer, thanks to `max_line_width = 0`.
    const allocator = testing.allocator;
    const input = try allocator.alloc(u8, 20_000);
    defer allocator.free(input);
    @memset(input, ' ');
    input[0] = '[';
    input[10_000] = '}';
    input[input.len - 1] = ']';

    const options: ReportOptions = .{ .source_name = "long.json", .max_line_width = 0 };
    const slice = (try toSlice(allocator, input, options)).?;
    defer allocator.free(slice);

    var streamed: std.Io.Writer.Allocating = .init(allocator);
    defer streamed.deinit();
    try printWith(input, options, .{ .writer = &streamed.writer, .mode = .no_color });

    try testing.expect(slice.len > 20_000);
    try testing.expectEqualStrings(slice, streamed.written());
}

// Integration tests: `isValid` and `dom.parse` must agree on every input below.
const dom = @import("../dom/root.zig");

const testing = std.testing;

test "diagnose and output" {
    const input = "[1 2]";
    const diagnostic = diagnose(input, .{}).?;
    try testing.expectEqual(@as(usize, 3), diagnostic.span.offset);
    try testing.expectEqual(@as(usize, 1), diagnostic.line(input));
    try testing.expectEqual(@as(usize, 4), diagnostic.column(input));
    try testing.expect(std.meta.eql(Problem{ .expected_comma_or_array_end = '2' }, diagnostic.problem));
    try testing.expect(diagnose("[1,2]", .{}) == null);

    const expected =
        "input.json:1:4: error: expected ',' or ']', found '2'\n" ++
        "1 | [1 2]\n" ++
        "  |    ^\n";

    var written: std.Io.Writer.Allocating = .init(testing.allocator);
    defer written.deinit();
    try printWith(input, .{ .source_name = "input.json" }, .{ .writer = &written.writer, .mode = .no_color });
    try testing.expectEqualStrings(expected, written.written());

    const slice = (try toSlice(testing.allocator, input, .{ .source_name = "input.json" })).?;
    defer testing.allocator.free(slice);
    try testing.expectEqualStrings(expected, slice);

    var silent: std.Io.Writer.Allocating = .init(testing.allocator);
    defer silent.deinit();
    try print("[1,2]", .{});
    try printWith("[1,2]", .{}, .{ .writer = &silent.writer, .mode = .no_color });
    try testing.expectEqualStrings("", silent.written());
    try testing.expect(try toSlice(testing.allocator, "[1,2]", .{}) == null);

    try testing.expect(isValid("[1,2]", .{}));
    try testing.expect(!isValid(input, .{}));
}

/// Inputs `dom.parse` rejects, with or without the permissive options.
const malformed_inputs = [_][]const u8{
    "",
    "   ",
    "\xef\xbb\xbf{}",
    "{",
    "}",
    "[",
    "]",
    "[1",
    "[1,",
    "[1,]",
    "[1 2]",
    "[1,,2]",
    "[,1]",
    "[}",
    "[1}",
    "{,}",
    "{\"a\"}",
    "{\"a\":}",
    "{\"a\":1,}",
    "{\"a\":1 \"b\":2}",
    "{\"a\" 1}",
    "{1:2}",
    "{'a':1}",
    "{a:1}",
    "{\"a\":1}}",
    "[1]]",
    "01",
    "-01",
    "1.",
    ".5",
    "1e",
    "1e+",
    "+1",
    "1e309",
    "-1e309",
    "NaN",
    "nan",
    "Infinity",
    "-Infinity",
    "0xFF",
    "0b1010",
    "TRUE",
    "tru",
    "fals",
    "nul",
    "nullx",
    "1 x",
    "{} []",
    "1,2",
    "\"abc",
    "\"a\\q\"",
    "\"a\nb\"",
    "\"a\x01b\"",
    "\"\\u12\"",
    "\"\\uZZZZ\"",
    "\"\\uD800\"",
    "\"\\uD800\\u0041\"",
    "\"\\uDC00\"",
    "\"\xc2",
    "\"\xc2\"",
    "\"\xc0\x80\"",
    "\"\xe0\x80\x80\"",
    "\"\xed\xa0\x80\"",
    "\"\xf4\x90\x80\x80\"",
    "\"\xf5\x80\x80\x80\"",
    "\"\xff\"",
    "\"\x80\"",
    "// comment\n1",
    "/* comment */ 1",
    "1 /* comment */",
    "1 // comment",
    "/* unterminated",
    "[\"a\":1]",
    "{\"a\":[1,2}",
    "[[[[",
    "{\"a\":01}",
    "{\"a\":.5}",
    "{\"a\":+1}",
    "{\"a\":1.}",
    "{\"a\":1e}",
    "{\"a\":NaN}",
    "{\"a\":'b'}",
};

/// Inputs `dom.parse` accepts with the default options.
const valid_inputs = [_][]const u8{
    "null",
    "true",
    "false",
    "0",
    "-0",
    "1",
    "-1",
    "1.5",
    "-1.5e-3",
    "1E+2",
    "18446744073709551615",
    "1e308",
    "1e-308",
    "\"\"",
    "\"jsonz\"",
    "\"\\u0041\\u00e9\\u4e2d\"",
    "\"\\uD83D\\uDE00\"",
    "\"\\n\\t\\\\\\/\\b\\f\\r\"",
    "\"\xe4\xb8\xad\xe6\x96\x87\"",
    "\"\xf0\x9f\x98\x80\"",
    "[]",
    "{}",
    "[1,2,3]",
    "{\"a\":1}",
    "{\"a\":{\"b\":[1,2,{}]}}",
    "[[[[[[[[[]]]]]]]]]",
    " \t\r\n{\n  \"a\": [true, false, null]\n}\n",
    "{\"\":\"\"}",
    "{\"a\":\"\\u0000\"}",
};

/// Inputs that only the permissive options accept.
const permissive_inputs = [_]struct { input: []const u8, options: dom.ParseOptions }{
    .{ .input = "[1,]", .options = .{ .allow_trailing_commas = true } },
    .{ .input = "{\"a\":1,}", .options = .{ .allow_trailing_commas = true } },
    .{ .input = "[[1,],{\"a\":1,},]", .options = .{ .allow_trailing_commas = true } },
    .{ .input = "// comment\n1", .options = .{ .allow_comments = true } },
    .{ .input = "/* comment */ 1", .options = .{ .allow_comments = true } },
    .{ .input = "{\"a\":/* c */1}", .options = .{ .allow_comments = true } },
    .{ .input = "{/* c */ \"a\": 1, // tail\n}", .options = .{ .allow_comments = true, .allow_trailing_commas = true } },
    .{ .input = "// comment\n1", .options = .{ .allow_trailing_commas = true } },
    .{ .input = "[1,]", .options = .{ .allow_comments = true } },
};

/// The option combinations every corpus entry is checked under.
const option_sets = [_]dom.ParseOptions{
    .{},
    .{ .allow_trailing_commas = true },
    .{ .allow_comments = true },
    .{ .allow_comments = true, .allow_trailing_commas = true },
};

fn domAccepts(input: []const u8, options: dom.ParseOptions) !bool {
    var document = dom.parseWith(testing.allocator, input, options) catch |failure| switch (failure) {
        error.InvalidJson => return false,
        error.OutOfMemory => return failure,
    };
    document.deinit();
    return true;
}

fn expectAgreement(input: []const u8, options: dom.ParseOptions) !void {
    const accepts = try domAccepts(input, options);
    const valid = isValid(input, .{
        .allow_comments = options.allow_comments,
        .allow_trailing_commas = options.allow_trailing_commas,
    });
    if (accepts != valid) {
        std.debug.print("dom and diagnostic disagree on {s} (dom accepts: {}, check: {})\n", .{
            input,
            accepts,
            valid,
        });
        return error.TestUnexpectedResult;
    }
}

test "agreement: malformed" {
    for (malformed_inputs) |input| {
        for (option_sets) |options| try expectAgreement(input, options);
    }
}

test "agreement: valid" {
    for (valid_inputs) |input| {
        for (option_sets) |options| try expectAgreement(input, options);
    }
}

test "agreement: permissive" {
    for (permissive_inputs) |case| try expectAgreement(case.input, case.options);
}

test "agreement: deep nesting" {
    const depth = 20_000;
    const input = try testing.allocator.alloc(u8, depth * 2);
    defer testing.allocator.free(input);
    @memset(input[0..depth], '[');
    @memset(input[depth..], ']');
    try expectAgreement(input, .{});

    input[depth] = 'x';
    try expectAgreement(input[0 .. depth + 1], .{});
}

// Damages valid documents at random: the deterministic counterpart of the fuzz
// target in `fuzzy/fuzzy.zig`, and it runs on every platform.
test "agreement: random mutations" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    const alphabet = ",:{}[]\"\\09e-+ .x\n\t";

    var buffer: [256]u8 = undefined;
    for (0..5_000) |_| {
        const source = valid_inputs[random.uintLessThan(usize, valid_inputs.len)];
        @memcpy(buffer[0..source.len], source);
        var input: []u8 = buffer[0..source.len];

        const rounds = 1 + random.uintLessThan(usize, 4);
        for (0..rounds) |_| {
            if (input.len == 0) break;
            switch (random.uintLessThan(u8, 3)) {
                0 => input[random.uintLessThan(usize, input.len)] = alphabet[random.uintLessThan(usize, alphabet.len)],
                1 => input = input[0..random.uintLessThan(usize, input.len + 1)],
                else => {
                    if (input.len == buffer.len) continue;
                    const index = random.uintLessThan(usize, input.len + 1);
                    std.mem.copyBackwards(u8, buffer[index + 1 .. input.len + 1], buffer[index..input.len]);
                    buffer[index] = alphabet[random.uintLessThan(usize, alphabet.len)];
                    input = buffer[0 .. input.len + 1];
                },
            }
        }

        try expectAgreement(input, .{ .allow_comments = true, .allow_trailing_commas = true });
    }
}
