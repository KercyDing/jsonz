//! RFC 6901 JSON Pointer resolution over a DOM view.
//!
//! A pointer is a sequence of `/`-separated reference tokens; the empty string
//! selects the root. `~1` decodes to `/` and `~0` to `~`. Whether a token is an
//! object member or an array index is decided by the node it meets, and object
//! keys match by exact code point, without Unicode normalization.

const std = @import("std");
const view_mod = @import("view.zig");

const DocView = view_mod.DocView;

/// Errors from resolving a JSON Pointer: the access errors plus the pointer's
/// own syntax and evaluation failures.
pub const PointerError = view_mod.AccessError || error{
    InvalidPointer,
    InvalidArrayIndex,
    AmbiguousMember,
    PointerTooLong,
};

/// Resolves a runtime RFC 6901 JSON Pointer.
pub fn resolve(root: DocView, pointer: []const u8) PointerError!DocView {
    if (pointer.len == 0) return root;
    if (pointer[0] != '/') return error.InvalidPointer;
    if (!std.unicode.utf8ValidateSlice(pointer)) return error.InvalidPointer;

    var current = root;
    var rest: []const u8 = pointer[1..];
    while (true) {
        const end = std.mem.indexOfScalar(u8, rest, '/');
        const token: []const u8 = if (end) |index| rest[0..index] else rest;
        if (!validToken(token)) return error.InvalidPointer;
        current = try descendToken(current, token);
        rest = if (end) |index| rest[index + 1 ..] else return current;
    }
}

/// Resolves a comptime-known JSON Pointer. Syntax, escapes, and UTF-8 are
/// checked while compiling, and each token's array-index interpretation is
/// prepared there. Whether a token is an index or a member still depends on the
/// node kind it meets at runtime.
pub fn resolveStatic(root: DocView, comptime pointer: []const u8) PointerError!DocView {
    comptime validateComptime(pointer);
    var current = root;
    inline for (comptime segments(pointer)) |segment| {
        current = try descendSegment(current, segment);
    }
    return current;
}

/// Resolves a comptime-known pointer format. The format is expanded with
/// `std.fmt` semantics into a fixed stack buffer, so interpolation is textual
/// and never escapes anything, and the common pointer never allocates. A
/// formatted pointer longer than the buffer reports `error.PointerTooLong`.
pub fn resolveFmt(root: DocView, comptime fmt: []const u8, args: anytype) PointerError!DocView {
    var buffer: [4096]u8 = undefined;
    const pointer = std.fmt.bufPrint(&buffer, fmt, args) catch return error.PointerTooLong;
    return resolve(root, pointer);
}

/// A token of a comptime-known pointer, prepared for traversal.
const Segment = struct {
    /// The token text before `~0`/`~1` decoding.
    token: []const u8,
    /// The token as an array index, when it is one.
    index: ?usize,
    /// Whether the token is the RFC 6901 `-` array token.
    dash: bool,
};

fn descendToken(current: DocView, token: []const u8) PointerError!DocView {
    if (current.isObject()) return objectLookup(current, token);
    if (!current.isArray()) return error.UnexpectedType;
    if (std.mem.eql(u8, token, "-")) return error.OutOfBounds;
    const index = parseArrayIndex(token) orelse return error.InvalidArrayIndex;
    return current.getAt(index) orelse error.OutOfBounds;
}

fn descendSegment(current: DocView, segment: Segment) PointerError!DocView {
    if (current.isObject()) return objectLookup(current, segment.token);
    if (!current.isArray()) return error.UnexpectedType;
    if (segment.dash) return error.OutOfBounds;
    const index = segment.index orelse return error.InvalidArrayIndex;
    return current.getAt(index) orelse error.OutOfBounds;
}

/// Looks up one object member. A pointer that matches more than one member is
/// ambiguous, as RFC 6901 requires.
fn objectLookup(current: DocView, token: []const u8) PointerError!DocView {
    var found: ?DocView = null;
    var iterator = current.objectIterator() catch unreachable;
    while (iterator.next()) |entry| {
        if (!tokenEql(entry.key, token)) continue;
        if (found != null) return error.AmbiguousMember;
        found = entry.value;
    }
    return found orelse error.MissingField;
}

/// Compares a stored key with a pointer token, decoding `~0` and `~1` as it
/// goes. A single left-to-right pass gives the required `~1`-before-`~0`
/// semantics for free.
fn tokenEql(stored: []const u8, token: []const u8) bool {
    var stored_index: usize = 0;
    var index: usize = 0;
    while (index < token.len) {
        var decoded = token[index];
        if (decoded == '~') {
            if (index + 1 >= token.len) return false;
            decoded = switch (token[index + 1]) {
                '0' => '~',
                '1' => '/',
                else => return false,
            };
            index += 2;
        } else {
            index += 1;
        }
        if (stored_index >= stored.len or stored[stored_index] != decoded) return false;
        stored_index += 1;
    }
    return stored_index == stored.len;
}

fn validToken(token: []const u8) bool {
    var index: usize = 0;
    while (index < token.len) : (index += 1) {
        if (token[index] != '~') continue;
        if (index + 1 >= token.len) return false;
        if (token[index + 1] != '0' and token[index + 1] != '1') return false;
        index += 1;
    }
    return true;
}

/// Parses an RFC 6901 array index: `0`, or `[1-9][0-9]*` without overflow.
fn parseArrayIndex(token: []const u8) ?usize {
    if (token.len == 0) return null;
    if (token[0] == '0') return if (token.len == 1) 0 else null;
    if (token[0] < '1' or token[0] > '9') return null;
    var value: usize = 0;
    for (token) |byte| {
        if (byte < '0' or byte > '9') return null;
        value = std.math.mul(usize, value, 10) catch return null;
        value = std.math.add(usize, value, byte - '0') catch return null;
    }
    return value;
}

fn tokenCount(comptime pointer: []const u8) usize {
    if (pointer.len == 0) return 0;
    return std.mem.count(u8, pointer, "/");
}

fn segmentOf(token: []const u8) Segment {
    return .{
        .token = token,
        .index = parseArrayIndex(token),
        .dash = std.mem.eql(u8, token, "-"),
    };
}

fn validateComptime(comptime pointer: []const u8) void {
    if (pointer.len == 0) return;
    if (pointer[0] != '/') @compileError("JSON Pointer must be empty or start with '/'");
    if (!std.unicode.utf8ValidateSlice(pointer)) @compileError("JSON Pointer must be valid UTF-8");
    var rest: []const u8 = pointer[1..];
    while (true) {
        const end = std.mem.indexOfScalar(u8, rest, '/');
        const token: []const u8 = if (end) |index| rest[0..index] else rest;
        if (!validToken(token)) @compileError("JSON Pointer contains an invalid escape");
        rest = if (end) |index| rest[index + 1 ..] else return;
    }
}

fn segments(comptime pointer: []const u8) [tokenCount(pointer)]Segment {
    var result: [tokenCount(pointer)]Segment = undefined;
    var rest: []const u8 = if (pointer.len == 0) pointer else pointer[1..];
    for (&result) |*segment| {
        const end = std.mem.indexOfScalar(u8, rest, '/');
        const token: []const u8 = if (end) |index| rest[0..index] else rest;
        segment.* = segmentOf(token);
        if (end) |index| rest = rest[index + 1 ..];
    }
    return result;
}

const testing = std.testing;

test "token decoding" {
    try testing.expect(tokenEql("a/b", "a~1b"));
    try testing.expect(tokenEql("m~n", "m~0n"));
    try testing.expect(tokenEql("~1", "~01"));
    try testing.expect(tokenEql("~", "~0"));
    try testing.expect(tokenEql("", ""));
    try testing.expect(!tokenEql("a/b", "a~0b"));
    try testing.expect(!tokenEql("ab", "a~1b"));
    try testing.expect(!tokenEql("a/or", "a~2b"));
}

test "array index grammar" {
    try testing.expectEqual(@as(?usize, 0), parseArrayIndex("0"));
    try testing.expectEqual(@as(?usize, 10), parseArrayIndex("10"));
    try testing.expectEqual(@as(?usize, 123), parseArrayIndex("123"));
    try testing.expect(parseArrayIndex("") == null);
    try testing.expect(parseArrayIndex("00") == null);
    try testing.expect(parseArrayIndex("01") == null);
    try testing.expect(parseArrayIndex("+1") == null);
    try testing.expect(parseArrayIndex("-1") == null);
    try testing.expect(parseArrayIndex("1.0") == null);
    try testing.expect(parseArrayIndex("-") == null);
    try testing.expect(parseArrayIndex("99999999999999999999999999") == null);
}
