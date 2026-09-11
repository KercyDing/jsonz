//! Zig-style rendering for `jsonz.diagnostic`.
//!
//! The layout, palette and caret art follow the Zig compiler, plus a line-number
//! gutter and only the few lines around the problem, since a JSON document is
//! often one long minified line.

const std = @import("std");
const error_mod = @import("error.zig");

const Diagnostic = error_mod.Diagnostic;
const Location = error_mod.Location;
const Span = error_mod.Span;

pub const RenderOptions = struct {
    color: bool = false,
    source_name: []const u8 = "<input>",
    context_lines: u8 = 3,
    max_line_width: usize = 200,
};

/// ANSI styles, matching the Zig compiler's own palette.
const style = struct {
    const reset = "\x1b[0m";
    const bold = "\x1b[1m";
    const dim = "\x1b[2m";
    const red = "\x1b[31m";
    const green = "\x1b[32m";
    const cyan = "\x1b[36m";
};

pub fn render(
    diagnostic: Diagnostic,
    input: []const u8,
    writer: *std.Io.Writer,
    options: RenderOptions,
) std.Io.Writer.Error!void {
    const location = error_mod.locate(input, diagnostic.span.offset);
    const window = Window.init(input, location, options.context_lines);

    var annotations: [max_annotations]Annotation = undefined;
    var count: usize = 0;
    annotations[count] = .{ .span = diagnostic.span, .line = location.line };
    count += 1;

    // A note near the problem is drawn inline; a distant one becomes its own
    // block, and one without a location becomes a bare `note:` line.
    var distant: ?struct { span: Span, message: []const u8 } = null;
    var bare: ?[]const u8 = null;
    if (diagnostic.effectiveNote()) |note| {
        if (note.span) |span| {
            const line = error_mod.locate(input, span.offset).line;
            if (line >= window.first_line and line <= window.last_line) {
                annotations[count] = .{
                    .span = span,
                    .secondary = true,
                    .label = note.message,
                    .line = line,
                };
                count += 1;
            } else {
                distant = .{ .span = span, .message = note.message };
            }
        } else {
            bare = note.message;
        }
    }

    try writeHeader(writer, options, location, "error", style.red, .{ .problem = diagnostic }, input);
    try writeSnippet(writer, input, options, window, annotations[0..count]);

    if (bare) |message| try writeBareNote(writer, options, message);
    if (distant) |note| {
        try writer.writeByte('\n');
        try renderNoteBlock(note.span, note.message, input, writer, options);
    }
}

pub fn toSlice(
    allocator: std.mem.Allocator,
    diagnostic: Diagnostic,
    input: []const u8,
    options: RenderOptions,
) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    errdefer output.deinit();
    try render(diagnostic, input, &output.writer, options);
    return output.toOwnedSlice();
}

/// The most one diagnostic draws: the problem itself, and one nearby note.
const max_annotations = 2;

/// A span to underline, optionally labelled and drawn as a secondary annotation.
const Annotation = struct {
    span: Span,
    /// Text written after the caret art, used when the annotation has no header.
    label: ?[]const u8 = null,
    /// Secondary annotations are drawn with `-` instead of `^~~~`.
    secondary: bool = false,
    /// 1-based line of `span.offset`, so each line draws only its own annotations.
    line: usize,
};

const Message = union(enum) {
    problem: Diagnostic,
    text: []const u8,

    fn write(self: Message, input: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (self) {
            .problem => |diagnostic| try diagnostic.writeMessage(input, writer),
            .text => |text| try writer.writeAll(text),
        }
    }
};

/// The range of source lines shown around an annotation.
const Window = struct {
    first_line: usize,
    last_line: usize,
    first_offset: usize,
    elided_before: bool,
    elided_after: bool,

    fn init(input: []const u8, location: Location, context_lines: u8) Window {
        var first_line = location.line;
        var first_offset = location.line_start;
        var remaining = context_lines;
        while (remaining > 0 and first_offset > 0) : (remaining -= 1) {
            first_line -= 1;
            if (std.mem.lastIndexOfScalar(u8, input[0 .. first_offset - 1], '\n')) |index| {
                first_offset = index + 1;
            } else {
                first_offset = 0;
                break;
            }
        }

        var last_line = location.line;
        var last_offset = location.line_end;
        var last_remaining = context_lines;
        while (last_remaining > 0 and last_offset < input.len) : (last_remaining -= 1) {
            const next_start = last_offset + 1;
            last_line += 1;
            if (std.mem.indexOfScalar(u8, input[next_start..], '\n')) |index| {
                last_offset = next_start + index;
            } else {
                last_offset = input.len;
                break;
            }
        }

        return .{
            .first_line = first_line,
            .last_line = last_line,
            .first_offset = first_offset,
            .elided_before = first_offset > 0,
            .elided_after = last_offset < input.len,
        };
    }
};

fn renderNoteBlock(
    span: Span,
    message: []const u8,
    input: []const u8,
    writer: *std.Io.Writer,
    options: RenderOptions,
) std.Io.Writer.Error!void {
    const location = error_mod.locate(input, span.offset);
    const window = Window.init(input, location, options.context_lines);
    try writeHeader(writer, options, location, "note", style.cyan, .{ .text = message }, input);
    try writeSnippet(writer, input, options, window, &.{.{ .span = span, .secondary = true, .line = location.line }});
}

fn setStyle(
    writer: *std.Io.Writer,
    options: RenderOptions,
    code: []const u8,
) std.Io.Writer.Error!void {
    if (options.color) try writer.writeAll(code);
}

fn writeHeader(
    writer: *std.Io.Writer,
    options: RenderOptions,
    location: Location,
    level: []const u8,
    level_style: []const u8,
    message: Message,
    input: []const u8,
) std.Io.Writer.Error!void {
    // The Zig compiler's exact sequences: bold location, coloured level, bold message.
    try setStyle(writer, options, style.bold);
    try writer.print("{s}:{d}:{d}: ", .{ options.source_name, location.line, location.column });
    try setStyle(writer, options, level_style);
    try writer.print("{s}: ", .{level});
    try setStyle(writer, options, style.reset);
    try setStyle(writer, options, style.bold);
    try message.write(input, writer);
    try writer.writeByte('\n');
    try setStyle(writer, options, style.reset);
}

fn writeBareNote(
    writer: *std.Io.Writer,
    options: RenderOptions,
    message: []const u8,
) std.Io.Writer.Error!void {
    try setStyle(writer, options, style.cyan);
    try writer.writeAll("note: ");
    try setStyle(writer, options, style.reset);
    try writer.writeAll(message);
    try writer.writeByte('\n');
}

fn writeSnippet(
    writer: *std.Io.Writer,
    input: []const u8,
    options: RenderOptions,
    window: Window,
    annotations: []const Annotation,
) std.Io.Writer.Error!void {
    const width = decimalDigits(window.last_line);
    if (window.elided_before) try writer.writeAll("...\n");

    var line_no = window.first_line;
    var line_start = window.first_offset;
    while (line_no <= window.last_line) : (line_no += 1) {
        const relative = std.mem.indexOfScalar(u8, input[line_start..], '\n');
        const line_end = if (relative) |index| line_start + index else input.len;
        // A CRLF line break is trivia, not content.
        var bytes = input[line_start..line_end];
        if (std.mem.endsWith(u8, bytes, "\r")) bytes = bytes[0 .. bytes.len - 1];
        try writeSourceLine(
            writer,
            options,
            width,
            line_no,
            line_start,
            .{ .bytes = bytes },
            annotations,
        );
        if (line_end == input.len) break;
        line_start = line_end + 1;
    }

    if (window.elided_after) try writer.writeAll("...\n");
}

fn writeSourceLine(
    writer: *std.Io.Writer,
    options: RenderOptions,
    gutter_width: usize,
    line_no: usize,
    line_start: usize,
    line: Line,
    annotations: []const Annotation,
) std.Io.Writer.Error!void {
    var line_annotations: [max_annotations]Placed = undefined;
    var count: usize = 0;
    for (annotations) |annotation| {
        if (annotation.line != line_no) continue;
        const start = @min(annotation.span.offset -| line_start, line.bytes.len);
        line_annotations[count] = .{
            .annotation = annotation,
            .column = line.columnAt(start),
            .width = @max(annotation.span.len, 1),
        };
        count += 1;
    }

    const total = line.width();
    var cut: Cut = .{ .from = 0, .to = total };
    if (options.max_line_width != 0 and total > options.max_line_width) {
        const focus = if (count == 0) 0 else line_annotations[0].column;
        cut = Cut.around(focus, total, options.max_line_width);
    }

    try setStyle(writer, options, style.dim);
    try writeGutterNumber(writer, line_no, gutter_width);
    try setStyle(writer, options, style.reset);

    if (cut.left_elided or cut.right_elided or cut.to > cut.from) {
        try writer.writeByte(' ');
        if (cut.left_elided) try writer.writeAll("...");
        try line.write(writer, cut.from, cut.to);
        if (cut.right_elided) try writer.writeAll("...");
    }
    try writer.writeByte('\n');

    for (line_annotations[0..count]) |placed| {
        try writeCaretLine(writer, options, gutter_width, cut, placed);
    }
}

/// An annotation placed on one source line.
const Placed = struct {
    annotation: Annotation,
    column: usize,
    width: usize,
};

fn writeCaretLine(
    writer: *std.Io.Writer,
    options: RenderOptions,
    gutter_width: usize,
    cut: Cut,
    placed: Placed,
) std.Io.Writer.Error!void {
    const visible_start = @max(placed.column, cut.from);
    const visible_end = @min(placed.column + placed.width, cut.to);
    const width = @max(visible_end -| visible_start, 1);
    const elision: usize = if (cut.left_elided) 3 else 0;

    try setStyle(writer, options, style.dim);
    try writeRepeated(writer, ' ', gutter_width);
    try writer.writeAll(" |");
    try setStyle(writer, options, style.reset);
    try writer.writeByte(' ');
    try writeRepeated(writer, ' ', elision + (visible_start - cut.from));

    try setStyle(writer, options, style.green);
    if (placed.annotation.secondary) {
        try writeRepeated(writer, '-', width);
    } else {
        try writer.writeByte('^');
        try writeRepeated(writer, '~', width - 1);
    }
    try setStyle(writer, options, style.reset);

    if (placed.annotation.label) |label| {
        try writer.writeByte(' ');
        try writer.writeAll(label);
    }
    try writer.writeByte('\n');
}

/// A horizontal window into one source line, in display columns.
const Cut = struct {
    from: usize,
    to: usize,
    left_elided: bool = false,
    right_elided: bool = false,

    fn around(focus: usize, total: usize, limit: usize) Cut {
        var from = focus -| (limit / 2);
        const to = @min(from + limit, total);
        if (to - from < limit) from = to -| limit;
        return .{
            .from = from,
            .to = to,
            .left_elided = from > 0,
            .right_elided = to < total,
        };
    }
};

/// One source line, with the display-column helpers.
const Line = struct {
    bytes: []const u8,

    fn width(self: Line) usize {
        var total: usize = 0;
        for (self.bytes) |byte| total += elementWidth(byte);
        return total;
    }

    fn columnAt(self: Line, offset: usize) usize {
        const head = Line{ .bytes = self.bytes[0..@min(offset, self.bytes.len)] };
        return head.width();
    }

    fn offsetAt(self: Line, column: usize) usize {
        var current: usize = 0;
        for (self.bytes, 0..) |byte, index| {
            if (current >= column) return index;
            current += elementWidth(byte);
        }
        return self.bytes.len;
    }

    fn write(self: Line, writer: *std.Io.Writer, from: usize, to: usize) std.Io.Writer.Error!void {
        for (self.bytes[self.offsetAt(from)..self.offsetAt(to)]) |byte| {
            if (byte == '\t') {
                try writer.writeByte(' ');
            } else if (byte < 0x20) {
                // Escaped, so a stray escape byte cannot reach the terminal.
                try writer.print("\\x{x:0>2}", .{byte});
            } else {
                try writer.writeByte(byte);
            }
        }
    }
};

/// The display width of one byte: a tab is printed as a space, and a control
/// byte as `\xNN`, so it takes four columns.
fn elementWidth(byte: u8) usize {
    if (byte == '\t') return 1;
    return if (byte < 0x20) 4 else 1;
}

fn writeGutterNumber(writer: *std.Io.Writer, line_no: usize, width: usize) std.Io.Writer.Error!void {
    try writer.print("{d:>[1]} |", .{ line_no, width });
}

fn writeRepeated(writer: *std.Io.Writer, byte: u8, count: usize) std.Io.Writer.Error!void {
    var remaining = count;
    while (remaining > 0) : (remaining -= 1) try writer.writeByte(byte);
}

fn decimalDigits(value: usize) usize {
    var digits: usize = 1;
    var remaining = value;
    while (remaining >= 10) : (remaining /= 10) digits += 1;
    return digits;
}

const testing = std.testing;
const check_mod = @import("check.zig");

/// Spaces as a comptime array, so golden tests do not count them by hand.
fn spaces(comptime count: usize) [count]u8 {
    var buffer: [count]u8 = undefined;
    @memset(&buffer, ' ');
    return buffer;
}

fn renderInput(input: []const u8, options: RenderOptions) ![]u8 {
    const diagnostic = check_mod.check(input, .{}) orelse return error.TestUnexpectedResult;
    return toSlice(testing.allocator, diagnostic, input, options);
}

fn expectSnippet(input: []const u8, options: RenderOptions, expected: []const u8) !void {
    const output = try renderInput(input, options);
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(expected, output);
}

test "missing comma" {
    try expectSnippet(
        "[1 2]",
        .{ .source_name = "input.json" },
        "input.json:1:4: error: expected ',' or ']', found '2'\n" ++
            "1 | [1 2]\n" ++
            "  |    ^\n",
    );
}

test "string with a raw newline" {
    try expectSnippet(
        "{\n  \"name\": \"json\n}",
        .{ .source_name = "config.json" },
        "config.json:2:16: error: string literal contains invalid byte: '\\n'\n" ++
            "1 | {\n" ++
            "2 |   \"name\": \"json\n" ++
            "  |                ^\n" ++
            "3 | }\n" ++
            "note: write '\\n' instead of a literal newline\n",
    );
}

test "unclosed string" {
    try expectSnippet(
        "{\n  \"a\": 1,\n  \"b\": \"xyz",
        .{ .source_name = "input.json" },
        "input.json:3:12: error: expected '\"', found 'EOF'\n" ++
            "1 | {\n" ++
            "2 |   \"a\": 1,\n" ++
            "3 |   \"b\": \"xyz\n" ++
            "  |            ^\n" ++
            "  |        - the string is never closed\n",
    );
}

test "elided window" {
    try expectSnippet(
        "[\n1,\n2,\n3,\n4,\n5,\nx,\n7,\n8\n]",
        .{ .source_name = "input.json" },
        "input.json:7:1: error: expected a JSON value, found 'x'\n" ++
            "...\n" ++
            " 4 | 3,\n" ++
            " 5 | 4,\n" ++
            " 6 | 5,\n" ++
            " 7 | x,\n" ++
            "   | ^\n" ++
            " 8 | 7,\n" ++
            " 9 | 8\n" ++
            "10 | ]\n",
    );
}

test "trailing comma" {
    try expectSnippet(
        "{\"a\":1,}",
        .{ .source_name = "input.json" },
        "input.json:1:7: error: trailing comma is not allowed\n" ++
            "1 | {\"a\":1,}\n" ++
            "  |       ^\n" ++
            "note: remove the trailing ','; JSON does not allow one, and .allow_trailing_commas = true accepts it\n",
    );
}

test "number out of range" {
    try expectSnippet(
        "1e309",
        .{ .source_name = "input.json" },
        "input.json:1:1: error: number is out of range for a double\n" ++
            "1 | 1e309\n" ++
            "  | ^~~~~\n" ++
            "note: JSON numbers are read as i64, u64 or f64; this one converts to infinity\n",
    );
}

test "distant note" {
    try expectSnippet(
        "{\n  \"a\": 1,\n  \"b\": 2,\n  \"c\": 3,\n  \"d\": 4,\n  \"e\": 5\n",
        .{ .source_name = "input.json" },
        "input.json:7:1: error: expected '}', found 'EOF'\n" ++
            "...\n" ++
            "4 |   \"c\": 3,\n" ++
            "5 |   \"d\": 4,\n" ++
            "6 |   \"e\": 5\n" ++
            "7 |\n" ++
            "  | ^\n" ++
            "\n" ++
            "input.json:1:1: note: the object starts here\n" ++
            "1 | {\n" ++
            "  | -\n" ++
            "2 |   \"a\": 1,\n" ++
            "3 |   \"b\": 2,\n" ++
            "4 |   \"c\": 3,\n" ++
            "...\n",
    );
}

test "tabs and control bytes" {
    try expectSnippet(
        "[\t\"a\", \"b\x01c\"]",
        .{ .source_name = "input.json" },
        "input.json:1:10: error: string literal contains invalid byte: '\\x01'\n" ++
            "1 | [ \"a\", \"b\\x01c\"]\n" ++
            "  |          ^\n" ++
            "note: escape it as \\u00XX\n",
    );
}

test "cut long line" {
    try expectSnippet(
        "[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 12]",
        .{ .source_name = "input.json", .max_line_width = 20 },
        "input.json:1:36: error: expected ',' or ']', found '1'\n" ++
            "1 | ... 7, 8, 9, 10, 11 12]\n" ++
            "  |                     ^\n",
    );

    try expectSnippet(
        "[1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 12]",
        .{ .source_name = "input.json", .max_line_width = 0 },
        "input.json:1:36: error: expected ',' or ']', found '1'\n" ++
            "1 | [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 12]\n" ++
            "  |" ++ spaces(36) ++ "^\n",
    );
}

test "CRLF line break" {
    try expectSnippet(
        "{\r\n  \"a\": 1,\r\n  \"b\": bad\r\n}",
        .{ .source_name = "input.json" },
        "input.json:3:8: error: expected a JSON value, found 'b'\n" ++
            "1 | {\n" ++
            "2 |   \"a\": 1,\n" ++
            "3 |   \"b\": bad\n" ++
            "  |        ^\n" ++
            "4 | }\n",
    );
}

test "colours" {
    const diagnostic = check_mod.check("[1 2]", .{}).?;
    const output = try toSlice(testing.allocator, diagnostic, "[1 2]", .{
        .source_name = "i",
        .color = true,
    });
    defer testing.allocator.free(output);
    try testing.expectEqualStrings(
        "\x1b[1mi:1:4: \x1b[31merror: \x1b[0m\x1b[1mexpected ',' or ']', found '2'\n" ++
            "\x1b[0m" ++
            "\x1b[2m1 |\x1b[0m [1 2]\n" ++
            "\x1b[2m  |\x1b[0m" ++ spaces(4) ++ "\x1b[32m^\x1b[0m\n",
        output,
    );
}

test "bounded output" {
    const allocator = testing.allocator;
    const input = try allocator.alloc(u8, 200_000);
    defer allocator.free(input);
    @memset(input, ' ');
    input[0] = '[';
    input[100_000] = '}';
    input[input.len - 1] = ']';

    const diagnostic = check_mod.check(input, .{}).?;
    const output = try toSlice(allocator, diagnostic, input, .{ .source_name = "long.json" });
    defer allocator.free(output);
    try testing.expect(output.len < 400);
    try testing.expect(std.mem.startsWith(u8, output, "long.json:1:100001: error: "));
    try testing.expect(std.mem.indexOf(u8, output, "...") != null);
    try testing.expect(std.mem.indexOf(u8, output, "^") != null);
}

test "unclosed object" {
    try expectSnippet(
        "{\n  \"name\": \"jsonz\",\n  \"tags\": [\"zig\", \"json\"]\n",
        .{ .source_name = "config.json" },
        "config.json:4:1: error: expected '}', found 'EOF'\n" ++
            "1 | {\n" ++
            "  | - the object starts here\n" ++
            "2 |   \"name\": \"jsonz\",\n" ++
            "3 |   \"tags\": [\"zig\", \"json\"]\n" ++
            "4 |\n" ++
            "  | ^\n",
    );
}
