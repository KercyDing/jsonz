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
//! `printWith` stream the report; `toSlice` materialises it.

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

const testing = std.testing;

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
