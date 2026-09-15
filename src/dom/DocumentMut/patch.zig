//! RFC 6902 JSON Patch.
//!
//! A patch is a JSON array of operations, applied in order. Each operation
//! names a location with an RFC 6901 JSON Pointer.
const std = @import("std");
const Document = @import("../Document/root.zig");
const DocumentMut = @import("DocumentMut.zig");
const NodeMut = @import("NodeMut.zig");
const rfc = @import("../rfc.zig");

/// Errors returned while applying a patch.
pub const Error = Document.ParseError || NodeMut.PointerError || NodeMut.MutateError || error{
    /// The patch is not a JSON array of valid operation objects.
    InvalidPatch,
    /// The operation is not defined for the target location.
    InvalidTarget,
    /// A `test` operation found a different value.
    TestFailed,
    /// `move` would move a value into its own child.
    InvalidMove,
};

/// Options that control how a patch is read.
pub const Options = struct {
    /// Parse options for the patch document.
    parse: Document.ParseOptions = .{},
};

/// Applies `patch` to `document` atomically: when an operation fails, the
/// document is left unchanged.
///
/// The operations run on a private copy that is committed only on success, so a
/// large document pays one extra deep copy. `applyOps` edits in place instead.
pub fn apply(document: *DocumentMut, patch: []const u8, options: Options) Error!void {
    const allocator = document.storage.allocator;
    var parsed = try Document.parse(allocator, patch, options.parse);
    defer parsed.deinit();
    var ops = try parsed.toMut(allocator);
    defer ops.deinit();

    var working = try DocumentMut.clone(allocator, document);
    defer working.deinit();
    try applyOps(&working, ops.root());
    try document.root().copyFrom(working.root());
}

/// Applies a parsed patch in place, in order. Operations that already ran stay
/// applied when a later one fails.
pub fn applyOps(document: *DocumentMut, ops: NodeMut) Error!void {
    if (!ops.isArray()) return error.InvalidPatch;
    var iterator = ops.arrayIterator() catch return error.InvalidPatch;
    while (iterator.next()) |operation| try applyOp(document, operation);
}

fn applyOp(document: *DocumentMut, operation: NodeMut) Error!void {
    if (!operation.isObject()) return error.InvalidPatch;
    const name = try stringMember(operation, "op");
    const path = try stringMember(operation, "path");

    if (std.mem.eql(u8, name, "add")) return add(document, path, try member(operation, "value"));
    if (std.mem.eql(u8, name, "remove")) return remove(document, path);
    if (std.mem.eql(u8, name, "replace")) return replace(document, path, try member(operation, "value"));
    if (std.mem.eql(u8, name, "move")) return move(document, try stringMember(operation, "from"), path);
    if (std.mem.eql(u8, name, "copy")) return copy(document, try stringMember(operation, "from"), path);
    if (std.mem.eql(u8, name, "test")) return testValue(document, path, try member(operation, "value"));
    return error.InvalidPatch;
}

/// Returns an operation's required member, or `error.InvalidPatch`.
fn member(operation: NodeMut, name: []const u8) Error!NodeMut {
    return operation.get(name) orelse error.InvalidPatch;
}

/// Returns an operation's required string member, or `error.InvalidPatch`.
fn stringMember(operation: NodeMut, name: []const u8) Error![]const u8 {
    const value = operation.get(name) orelse return error.InvalidPatch;
    return value.asString() orelse error.InvalidPatch;
}

/// A pointer split into the container it selects from and its last token.
const Target = struct {
    /// Pointer text of the container that holds the target.
    parent: []const u8,
    /// Last reference token, still escaped.
    token: []const u8,
};

/// Splits `pointer`; `null` means the pointer selects the whole document.
fn split(pointer: []const u8) NodeMut.PointerError!?Target {
    if (pointer.len == 0) return null;
    if (pointer[0] != '/') return error.InvalidPointer;
    if (!std.unicode.utf8ValidateSlice(pointer)) return error.InvalidPointer;
    const cut = std.mem.lastIndexOfScalar(u8, pointer, '/').?;
    const token = pointer[cut + 1 ..];
    if (!rfc.validToken(token)) return error.InvalidPointer;
    return .{ .parent = pointer[0..cut], .token = token };
}

/// Adds `value` at `path`: an object member is set, an array element is
/// inserted (`-` appends), and an empty path replaces the whole document.
fn add(document: *DocumentMut, path: []const u8, value: NodeMut) Error!void {
    const target = (try split(path)) orelse return document.root().copyFrom(value);
    const container = try document.ptrGetDyn(target.parent);

    if (container.isObject()) {
        var key: TokenBuffer = .init(document.storage.allocator);
        defer key.deinit();
        const name = try key.decode(target.token);
        if (container.get(name)) |existing| return existing.copyFrom(value);
        const fresh = try document.newNull();
        try fresh.copyFrom(value);
        return container.addField(name, fresh);
    }
    if (container.isArray()) {
        const fresh = try document.newNull();
        try fresh.copyFrom(value);
        if (std.mem.eql(u8, target.token, "-")) return container.append(fresh);
        const index = rfc.parseArrayIndex(target.token) orelse return error.InvalidArrayIndex;
        return container.insertAt(index, fresh);
    }
    return error.InvalidTarget;
}

/// Removes the value at `path`, which must exist.
fn remove(document: *DocumentMut, path: []const u8) Error!void {
    const target = (try split(path)) orelse return error.InvalidTarget;
    const container = try document.ptrGetDyn(target.parent);

    if (container.isObject()) {
        var key: TokenBuffer = .init(document.storage.allocator);
        defer key.deinit();
        const name = try key.decode(target.token);
        const existing = container.get(name) orelse return error.MissingField;
        existing.remove();
        return;
    }
    if (container.isArray()) {
        const index = rfc.parseArrayIndex(target.token) orelse return error.InvalidArrayIndex;
        const existing = container.getAt(index) orelse return error.OutOfBounds;
        existing.remove();
        return;
    }
    return error.InvalidTarget;
}

/// Replaces the value at `path`, which must exist.
fn replace(document: *DocumentMut, path: []const u8, value: NodeMut) Error!void {
    const target = (try split(path)) orelse return document.root().copyFrom(value);
    const container = try document.ptrGetDyn(target.parent);

    if (container.isObject()) {
        var key: TokenBuffer = .init(document.storage.allocator);
        defer key.deinit();
        const name = try key.decode(target.token);
        const existing = container.get(name) orelse return error.MissingField;
        return existing.copyFrom(value);
    }
    if (container.isArray()) {
        const index = rfc.parseArrayIndex(target.token) orelse return error.InvalidArrayIndex;
        const existing = container.getAt(index) orelse return error.OutOfBounds;
        return existing.copyFrom(value);
    }
    return error.InvalidTarget;
}

/// Moves the value at `from` to `path`.
fn move(document: *DocumentMut, from: []const u8, path: []const u8) Error!void {
    if (from.len == 0) return error.InvalidTarget;
    if (isProperPrefix(from, path)) return error.InvalidMove;
    const source = try document.ptrGetDyn(from);
    source.remove();
    return add(document, path, source);
}

/// Copies the value at `from` to `path`.
fn copy(document: *DocumentMut, from: []const u8, path: []const u8) Error!void {
    return add(document, path, try document.ptrGetDyn(from));
}

/// Requires the value at `path` to equal `value`.
fn testValue(document: *DocumentMut, path: []const u8, value: NodeMut) Error!void {
    const actual = try document.ptrGetDyn(path);
    if (!try eql(document.storage.allocator, actual, value)) return error.TestFailed;
}

/// Whether `prefix` is a proper prefix of `pointer`, which for `move` means the
/// destination sits inside the value being moved.
fn isProperPrefix(prefix: []const u8, pointer: []const u8) bool {
    if (prefix.len >= pointer.len) return false;
    if (!std.mem.startsWith(u8, pointer, prefix)) return false;
    return prefix.len == 0 or pointer[prefix.len] == '/';
}

/// A pair of nodes still to compare.
const Pair = struct { a: NodeMut, b: NodeMut };

/// Structural equality as RFC 6902 defines it for `test`: numbers compare by
/// value, object members are unordered, arrays are ordered.
///
/// Iterative, so a deeply nested value cannot overflow the stack.
fn eql(allocator: std.mem.Allocator, a: NodeMut, b: NodeMut) Error!bool {
    var stack: std.ArrayList(Pair) = .empty;
    defer stack.deinit(allocator);
    try stack.append(allocator, .{ .a = a, .b = b });

    while (stack.pop()) |pair| {
        const left = pair.a;
        const right = pair.b;
        if (left.kind() != right.kind()) return false;
        switch (left.kind()) {
            .null => {},
            .bool => {
                if (left.asBool().? != right.asBool().?) return false;
            },
            .number => {
                if (!numberEql(left, right)) return false;
            },
            .string => {
                if (!std.mem.eql(u8, left.asString().?, right.asString().?)) return false;
            },
            .array => {
                if (try left.len() != try right.len()) return false;
                var left_elements = try left.arrayIterator();
                var right_elements = try right.arrayIterator();
                while (left_elements.next()) |element| {
                    try stack.append(allocator, .{ .a = element, .b = right_elements.next().? });
                }
            },
            .object => {
                if (try left.len() != try right.len()) return false;
                var members = try left.objectIterator();
                while (members.next()) |entry| {
                    const match = right.get(entry.key) orelse return false;
                    try stack.append(allocator, .{ .a = entry.value, .b = match });
                }
            },
        }
    }
    return true;
}

/// Numeric equality: two integers compare exactly, and a real compares to an
/// integer by value without rounding the integer through a float.
fn numberEql(a: NodeMut, b: NodeMut) bool {
    const a_integer = a.asNumber(.i128);
    const b_integer = b.asNumber(.i128);
    if (a_integer != null and b_integer != null) return a_integer.? == b_integer.?;
    if (a_integer) |integer| return intAndRealEql(integer, b.asNumber(.f64) orelse return false);
    if (b_integer) |integer| return intAndRealEql(integer, a.asNumber(.f64) orelse return false);
    const a_real = a.asNumber(.f64) orelse return false;
    const b_real = b.asNumber(.f64) orelse return false;
    return a_real == b_real;
}

fn intAndRealEql(integer: i128, real: f64) bool {
    if (real != @trunc(real)) return false;
    if (real < @as(f64, @floatFromInt(std.math.minInt(i128)))) return false;
    if (real >= @as(f64, @floatFromInt(std.math.maxInt(i128)))) return false;
    return @as(i128, @intFromFloat(real)) == integer;
}

/// Decodes a pointer token, borrowing `token` itself when it holds no escape
/// and falling back to the heap for a key longer than the inline buffer.
const TokenBuffer = struct {
    allocator: std.mem.Allocator,
    inline_buffer: [256]u8 = undefined,
    owned: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator) TokenBuffer {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *TokenBuffer) void {
        if (self.owned) |owned| self.allocator.free(owned);
    }

    fn decode(self: *TokenBuffer, token: []const u8) Error![]const u8 {
        if (std.mem.indexOfScalar(u8, token, '~') == null) return token;
        if (token.len <= self.inline_buffer.len) return rfc.decodeToken(&self.inline_buffer, token);
        const owned = try self.allocator.alloc(u8, token.len);
        self.owned = owned;
        return rfc.decodeToken(owned, token);
    }
};
