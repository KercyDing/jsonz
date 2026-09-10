const std = @import("std");
const float = @import("float");
const pool_mod = @import("pool.zig");

const Pool = pool_mod.Pool;
const Subtype = pool_mod.Subtype;
const Type = pool_mod.Type;
const Value = pool_mod.Value;

/// Bytes checked at once while scanning a string for characters that need work.
const scan_chunk = 32;
const ScanVector = @Vector(scan_chunk, u8);

/// Bit `i` is set when byte `i` of the chunk is a quote, an escape, a control
/// byte, or a non-ASCII byte; `@ctz` then points at the first of them, so a
/// plain ASCII run can be skipped or copied in one go.
inline fn specialMask(bytes: ScanVector) u32 {
    const quote = bytes == @as(ScanVector, @splat('"'));
    const escape = bytes == @as(ScanVector, @splat('\\'));
    const control = bytes < @as(ScanVector, @splat(0x20));
    const high = bytes > @as(ScanVector, @splat(0x7f));
    return @bitCast(quote | escape | control | high);
}

/// Continuation-byte count for a UTF-8 lead byte, or `0xFF` when invalid.
///
/// This is the same accepted set as yyjson: continuation bytes and overlong
/// two-byte leads (`0x80..0xC1`) and leads above `0xF4` are invalid.
const utf8_continuations: [256]u8 = blk: {
    var table: [256]u8 = @splat(0xFF);
    for (0x00..0x80) |i| table[i] = 0;
    for (0xC2..0xE0) |i| table[i] = 1;
    for (0xE0..0xF0) |i| table[i] = 2;
    for (0xF0..0xF5) |i| table[i] = 3;
    break :blk table;
};

/// Options that control DOM parsing, matching yyjson's read flags.
pub const Options = struct {
    /// Accept `//` and `/* ... */` comments, which are not part of standard JSON.
    allow_comments: bool = false,
    /// Accept a comma before a closing `]` or `}`, which is not part of standard JSON.
    allow_trailing_commas: bool = false,
};

pub const Error = error{ InvalidJson, OutOfMemory };

/// Parses the JSON in `input` into `pool` and returns the root value index.
///
/// `input` must stay mutable and alive as long as the pool is read: string
/// escape sequences are decoded in place, and every string value stores a byte
/// offset into `input`.
/// Parses the JSON in `buffer[0..end]` into `pool` and returns the root index.
///
/// `buffer` must have four readable zero bytes at `buffer[end..end + 4]`; the
/// reader uses them the way yyjson does, so its hot loops can skip bounds
/// checks. String escape sequences are decoded in place inside `buffer`.
pub fn read(pool: *Pool, buffer: []u8, end: usize, options: Options) Error!u32 {
    var reader: Reader = .{
        .input = buffer[0 .. end + 4],
        .end = end,
        .pool = pool,
        .options = options,
    };
    return reader.run();
}

const State = enum {
    root,
    array_value,
    array_end,
    object_key,
    object_colon,
    object_value,
    object_end,
    done,
};

/// A value's pool index and the input offset just past it.
const Scan = struct {
    index: u32,
    pos: usize,
};

/// The read cursor and write cursor after decoding an escape.
const Escape = struct {
    pos: usize,
    write: usize,
};

/// The result of closing a container, with the parent's restored counters.
const Closed = struct {
    state: State,
    pos: usize,
    current: u32,
    count: usize,
};

/// A value yielded by `scanValue`.
const Scanned = struct {
    index: u32,
    pos: usize,
    /// The state to parse the new container's contents in, or null for a scalar.
    container: ?State,
};

/// The result of opening a container: where to continue and in which state.
const Opened = struct {
    index: u32,
    pos: usize,
    state: State,
};

/// A goto-free port of yyjson's reader finite state machine.
///
/// The mutable cursor and container counters are locals in `run` rather than
/// fields, so writes to the input buffer and value pool cannot force LLVM to
/// spill and reload them on every value.
const Reader = struct {
    /// The padded input; `self.end == end + 4`.
    input: []u8,
    /// The logical end of the JSON text.
    end: usize,
    pool: *Pool,
    options: Options,

    fn run(self: *Reader) Error!u32 {
        const input = self.input;
        var pos: usize = 0;
        var current: u32 = 0;
        var count: usize = 0;
        var state: State = .root;
        var root: ?u32 = null;

        while (state != .done) {
            // Each state skips trivia exactly once; `scanValue` and the
            // separator checks below never scan it again.
            pos = try self.skipTrivia(pos);
            switch (state) {
                .root => {
                    if (pos == self.end) return error.InvalidJson;
                    const scanned = try self.scanValue(null, count, pos);
                    if (scanned.container) |container_state| {
                        root = scanned.index;
                        current = scanned.index;
                        count = 0;
                        state = container_state;
                        pos = scanned.pos;
                    } else {
                        root = scanned.index;
                        pos = try self.skipTrivia(scanned.pos);
                        if (pos != self.end) return error.InvalidJson;
                        state = .done;
                    }
                },
                .array_value => {
                    // Arrays of scalars are the densest shape in real
                    // documents, so consume a whole run of them here instead of
                    // bouncing through the state switch for every element.
                    run: while (true) {
                        if (pos == self.end) return error.InvalidJson;
                        const byte = input[pos];
                        if (byte == ']') {
                            pos += 1;
                            const closed = try self.closeContainer(current, count, pos);
                            state = closed.state;
                            pos = closed.pos;
                            current = closed.current;
                            count = closed.count;
                            break :run;
                        }
                        if (byte == '[' or byte == '{') {
                            const opened = try self.openContainer(
                                if (byte == '{') .object else .array,
                                current,
                                count,
                                pos,
                            );
                            current = opened.index;
                            count = 0;
                            pos = opened.pos;
                            state = opened.state;
                            break :run;
                        }
                        const scanned = try self.scanScalar(pos);
                        pos = scanned.pos;
                        count += 1;
                        pos = try self.skipTrivia(pos);
                        if (pos == self.end) return error.InvalidJson;
                        switch (input[pos]) {
                            ',' => {
                                pos += 1;
                                pos = try self.skipTrivia(pos);
                                if (pos < self.end and input[pos] == ']') {
                                    if (!self.options.allow_trailing_commas) return error.InvalidJson;
                                    pos += 1;
                                    const closed = try self.closeContainer(current, count, pos);
                                    state = closed.state;
                                    pos = closed.pos;
                                    current = closed.current;
                                    count = closed.count;
                                    break :run;
                                }
                            },
                            ']' => {
                                pos += 1;
                                const closed = try self.closeContainer(current, count, pos);
                                state = closed.state;
                                pos = closed.pos;
                                current = closed.current;
                                count = closed.count;
                                break :run;
                            },
                            else => return error.InvalidJson,
                        }
                    }
                    continue;
                },
                .array_end => {
                    if (pos == self.end) return error.InvalidJson;
                    switch (input[pos]) {
                        ',' => {
                            pos += 1;
                            pos = try self.skipTrivia(pos);
                            if (pos < self.end and input[pos] == ']') {
                                if (!self.options.allow_trailing_commas) return error.InvalidJson;
                                pos += 1;
                                const closed = try self.closeContainer(current, count, pos);
                                state = closed.state;
                                pos = closed.pos;
                                current = closed.current;
                                count = closed.count;
                            } else state = .array_value;
                        },
                        ']' => {
                            pos += 1;
                            const closed = try self.closeContainer(current, count, pos);
                            state = closed.state;
                            pos = closed.pos;
                            current = closed.current;
                            count = closed.count;
                        },
                        else => return error.InvalidJson,
                    }
                },
                .object_key => {
                    // As with arrays, run through scalar-valued pairs here so a
                    // compact object does not re-dispatch per member.
                    run: while (true) {
                        if (pos == self.end) return error.InvalidJson;
                        const byte = input[pos];
                        if (byte == '}') {
                            pos += 1;
                            const closed = try self.closeContainer(current, count, pos);
                            state = closed.state;
                            pos = closed.pos;
                            current = closed.current;
                            count = closed.count;
                            break :run;
                        }
                        if (byte != '"') return error.InvalidJson;
                        const key = try self.scanString(pos);
                        pos = key.pos;
                        count += 1;
                        pos = try self.skipTrivia(pos);
                        if (pos == self.end or input[pos] != ':') return error.InvalidJson;
                        pos += 1;
                        pos = try self.skipTrivia(pos);
                        if (pos == self.end) return error.InvalidJson;
                        const value_byte = input[pos];
                        if (value_byte == '[' or value_byte == '{') {
                            const opened = try self.openContainer(
                                if (value_byte == '{') .object else .array,
                                current,
                                count,
                                pos,
                            );
                            current = opened.index;
                            count = 0;
                            pos = opened.pos;
                            state = opened.state;
                            break :run;
                        }
                        const value = try self.scanScalar(pos);
                        pos = value.pos;
                        count += 1;
                        pos = try self.skipTrivia(pos);
                        if (pos == self.end) return error.InvalidJson;
                        switch (input[pos]) {
                            ',' => {
                                pos += 1;
                                pos = try self.skipTrivia(pos);
                                if (pos < self.end and input[pos] == '}') {
                                    if (!self.options.allow_trailing_commas) return error.InvalidJson;
                                    pos += 1;
                                    const closed = try self.closeContainer(current, count, pos);
                                    state = closed.state;
                                    pos = closed.pos;
                                    current = closed.current;
                                    count = closed.count;
                                    break :run;
                                }
                            },
                            '}' => {
                                pos += 1;
                                const closed = try self.closeContainer(current, count, pos);
                                state = closed.state;
                                pos = closed.pos;
                                current = closed.current;
                                count = closed.count;
                                break :run;
                            },
                            else => return error.InvalidJson,
                        }
                    }
                    continue;
                },
                .object_colon => {
                    if (pos == self.end or input[pos] != ':') return error.InvalidJson;
                    pos += 1;
                    state = .object_value;
                },
                .object_value => {
                    const scanned = try self.scanValue(current, count, pos);
                    pos = scanned.pos;
                    if (scanned.container) |container_state| {
                        current = scanned.index;
                        count = 0;
                        state = container_state;
                    } else {
                        count += 1;
                        state = .object_end;
                    }
                },
                .object_end => {
                    if (pos == self.end) return error.InvalidJson;
                    switch (input[pos]) {
                        ',' => {
                            pos += 1;
                            pos = try self.skipTrivia(pos);
                            if (pos < self.end and input[pos] == '}') {
                                if (!self.options.allow_trailing_commas) return error.InvalidJson;
                                pos += 1;
                                const closed = try self.closeContainer(current, count, pos);
                                state = closed.state;
                                pos = closed.pos;
                                current = closed.current;
                                count = closed.count;
                            } else state = .object_key;
                        },
                        '}' => {
                            pos += 1;
                            const closed = try self.closeContainer(current, count, pos);
                            state = closed.state;
                            pos = closed.pos;
                            current = closed.current;
                            count = closed.count;
                        },
                        else => return error.InvalidJson,
                    }
                },
                .done => unreachable,
            }
        }
        return root orelse unreachable;
    }

    /// Scans one value: a scalar value, or a container header that the caller
    /// must descend into.
    /// Scans one scalar value; containers are handled by the state machine.
    inline fn scanScalar(self: *Reader, pos: usize) Error!Scan {
        switch (self.input[pos]) {
            '"' => return self.scanString(pos),
            't' => return self.scanLiteral(pos, "true", .bool, pool_mod.true_value, 1),
            'f' => return self.scanLiteral(pos, "false", .bool, pool_mod.false_value, 0),
            'n' => return self.scanLiteral(pos, "null", .null, .none, 0),
            '-', '0'...'9' => return self.scanNumber(pos),
            else => return error.InvalidJson,
        }
    }

    inline fn scanValue(self: *Reader, parent: ?u32, count: usize, pos: usize) Error!Scanned {
        if (pos == self.end) return error.InvalidJson;
        const byte = self.input[pos];
        switch (byte) {
            '[' => {
                const opened = try self.openContainer(.array, parent, count, pos);
                return .{ .index = opened.index, .pos = opened.pos, .container = opened.state };
            },
            '{' => {
                const opened = try self.openContainer(.object, parent, count, pos);
                return .{ .index = opened.index, .pos = opened.pos, .container = opened.state };
            },
            '"' => {
                const scanned = try self.scanString(pos);
                return .{ .index = scanned.index, .pos = scanned.pos, .container = null };
            },
            't' => {
                const scanned = try self.scanLiteral(pos, "true", .bool, pool_mod.true_value, 1);
                return .{ .index = scanned.index, .pos = scanned.pos, .container = null };
            },
            'f' => {
                const scanned = try self.scanLiteral(pos, "false", .bool, pool_mod.false_value, 0);
                return .{ .index = scanned.index, .pos = scanned.pos, .container = null };
            },
            'n' => {
                const scanned = try self.scanLiteral(pos, "null", .null, .none, 0);
                return .{ .index = scanned.index, .pos = scanned.pos, .container = null };
            },
            '-', '0'...'9' => {
                const scanned = try self.scanNumber(pos);
                return .{ .index = scanned.index, .pos = scanned.pos, .container = null };
            },
            else => return error.InvalidJson,
        }
    }

    fn openContainer(
        self: *Reader,
        value_type: Type,
        parent: ?u32,
        count: usize,
        pos: usize,
    ) Error!Opened {
        const index = try self.append(pool_mod.makeTag(value_type, .none, 0), .{ .uint = 0 });
        if (parent) |parent_index| {
            // Count the new child in the parent. For an array this is its final
            // length; for an object it is the number of finished key/value
            // slots, converted to a pair count when the object closes.
            const parent_value = self.pool.at(parent_index).*;
            self.pool.atMut(parent_index).tag = pool_mod.makeTag(
                pool_mod.valueType(parent_value),
                .none,
                count + 1,
            );
            self.pool.atMut(index).uni.offset = pool_mod.byteOffset(parent_index, index);
        }
        return .{
            .index = index,
            .pos = pos + 1,
            .state = if (value_type == .object) .object_key else .array_value,
        };
    }

    fn closeContainer(self: *Reader, container: u32, count: usize, pos: usize) Error!Closed {
        const value = self.pool.at(container).*;
        const value_type = pool_mod.valueType(value);
        const parent = container - @as(u32, @intCast(value.uni.offset / pool_mod.value_size));
        const len = if (value_type == .object) count / 2 else count;
        // The offset points one value past the last child, so that walking
        // siblings can skip this whole subtree.
        self.pool.atMut(container).* = .{
            .tag = pool_mod.makeTag(value_type, .none, len),
            .uni = .{ .offset = pool_mod.byteOffset(container, @intCast(self.pool.len)) },
        };
        if (parent == container) {
            const end = try self.skipTrivia(pos);
            if (end != self.end) return error.InvalidJson;
            return .{ .state = .done, .pos = end, .current = container, .count = count };
        }

        const parent_value = self.pool.at(parent).*;
        return .{
            .state = if (pool_mod.valueType(parent_value) == .object) .object_end else .array_end,
            .pos = pos,
            .current = parent,
            .count = pool_mod.valueLen(parent_value),
        };
    }

    inline fn scanLiteral(
        self: *Reader,
        pos: usize,
        comptime text: []const u8,
        value_type: Type,
        subtype: Subtype,
        payload: u64,
    ) Error!Scan {
        // The zero padding keeps this read in bounds.
        if (!std.mem.eql(u8, self.input[pos..][0..text.len], text)) {
            return error.InvalidJson;
        }
        return .{
            .index = try self.append(pool_mod.makeTag(value_type, subtype, 0), .{ .uint = payload }),
            .pos = pos + text.len,
        };
    }

    /// Reads a number with a single scan.
    ///
    /// `float.scanNumber` reports the exact integer value when the token is a
    /// plain integer, and the significant digits a double conversion needs
    /// otherwise, so no digits are scanned twice.
    inline fn scanNumber(self: *Reader, start: usize) Error!Scan {
        const scanned = float.scanNumber(self.input[0..self.end], start) catch
            return error.InvalidJson;

        if (scanned.integer) |magnitude| {
            if (scanned.negative) {
                if (magnitude < (@as(u64, 1) << 63)) {
                    return .{
                        .index = try self.append(
                            pool_mod.makeTag(.number, pool_mod.sint, 0),
                            .{ .int = -@as(i64, @intCast(magnitude)) },
                        ),
                        .pos = scanned.end,
                    };
                } else if (magnitude == (@as(u64, 1) << 63)) {
                    return .{
                        .index = try self.append(
                            pool_mod.makeTag(.number, pool_mod.sint, 0),
                            .{ .int = std.math.minInt(i64) },
                        ),
                        .pos = scanned.end,
                    };
                }
            } else {
                return .{
                    .index = try self.append(
                        pool_mod.makeTag(.number, pool_mod.uint, 0),
                        .{ .uint = magnitude },
                    ),
                    .pos = scanned.end,
                };
            }
        }

        const value = float.convertScanned(f64, scanned) orelse
            (std.fmt.parseFloat(f64, self.input[start..scanned.end]) catch
                return error.InvalidJson);
        if (!std.math.isFinite(value)) return error.InvalidJson;
        return .{
            .index = try self.append(
                pool_mod.makeTag(.number, .real, 0),
                .{ .float = value },
            ),
            .pos = scanned.end,
        };
    }

    /// Reads a string value, decoding escapes in place.
    ///
    /// Strings without escapes take a scan-only fast path that never writes to
    /// the input buffer. Plain 32-byte chunks are skipped with SIMD; a chunk
    /// that contains a quote, escape, control byte, or non-ASCII byte is walked
    /// byte by byte before the vector scan resumes, so non-ASCII text does not
    /// pay for a vector reload per character.
    inline fn scanString(self: *Reader, start: usize) Error!Scan {
        const input = self.input;
        const text_start = start + 1;
        var scan = text_start;

        scan_loop: while (true) {
            while (scan + scan_chunk <= self.end) {
                const bytes: ScanVector = input[scan..][0..scan_chunk].*;
                const special = specialMask(bytes);
                if (special != 0) {
                    scan += @ctz(special);
                    break;
                }
                scan += scan_chunk;
            }
            const window_end = @min(scan + scan_chunk, self.end);
            while (scan < window_end) {
                const byte = input[scan];
                if (byte == '"') {
                    return .{
                        .index = try self.append(pool_mod.makeTag(.string, pool_mod.no_escape, scan - text_start), .{ .offset = text_start }),
                        .pos = scan + 1,
                    };
                }
                if (byte == '\\') break :scan_loop;
                if (byte < 0x20) return error.InvalidJson;
                if (byte >= 0x80) {
                    scan = try self.skipUtf8(scan);
                } else {
                    scan += 1;
                }
            }
            if (scan >= self.end) return error.InvalidJson;
        }

        // At least one escape: decode the rest in place. `write` trails `scan`
        // because escape sequences shrink.
        var pos = scan;
        var write = scan;
        while (true) {
            while (pos + scan_chunk <= self.end) {
                const bytes: ScanVector = input[pos..][0..scan_chunk].*;
                const special = specialMask(bytes);
                if (special != 0) {
                    const plain = @ctz(special);
                    if (plain != 0) {
                        std.mem.copyForwards(
                            u8,
                            input[write..][0..plain],
                            input[pos..][0..plain],
                        );
                        write += plain;
                        pos += plain;
                    }
                    break;
                }
                std.mem.copyForwards(
                    u8,
                    input[write..][0..scan_chunk],
                    input[pos..][0..scan_chunk],
                );
                write += scan_chunk;
                pos += scan_chunk;
            }
            const window_end = @min(pos + scan_chunk, self.end);
            while (pos < window_end) {
                const byte = input[pos];
                if (byte >= 0x20 and byte != '"' and byte != '\\' and byte < 0x80) {
                    input[write] = byte;
                    write += 1;
                    pos += 1;
                    continue;
                }
                switch (byte) {
                    '"' => {
                        return .{
                            .index = try self.append(pool_mod.makeTag(.string, .none, write - text_start), .{ .offset = text_start }),
                            .pos = pos + 1,
                        };
                    },
                    '\\' => {
                        pos += 1;
                        if (pos == self.end) return error.InvalidJson;
                        const escape = input[pos];
                        pos += 1;
                        if (escape == 'u') {
                            const decoded_escape = try self.readUnicodeEscape(pos, write);
                            pos = decoded_escape.pos;
                            write = decoded_escape.write;
                            continue;
                        }
                        const decoded: u8 = switch (escape) {
                            '"', '\\', '/' => escape,
                            'b' => 0x08,
                            'f' => 0x0c,
                            'n' => '\n',
                            'r' => '\r',
                            't' => '\t',
                            else => return error.InvalidJson,
                        };
                        input[write] = decoded;
                        write += 1;
                    },
                    0x00...0x1f => return error.InvalidJson,
                    else => {
                        // Validate the whole multi-byte run, then move it as one
                        // span; `write` never passes `pos`, so copy forwards.
                        const next = try self.skipUtf8(pos);
                        const len = next - pos;
                        std.mem.copyForwards(
                            u8,
                            input[write..][0..len],
                            input[pos..][0..len],
                        );
                        write += len;
                        pos = next;
                    },
                }
            }
            if (pos >= self.end) return error.InvalidJson;
        }
    }

    /// Advances over a run of UTF-8 sequences at `pos`, returning the offset of
    /// the first ASCII byte or the end of the run.
    ///
    /// This is yyjson's mask-and-pattern validation: one little-endian 32-bit
    /// load checks a whole sequence, so runs of same-length sequences (common
    /// for CJK text) move several bytes per iteration.
    fn skipUtf8(self: *Reader, start: usize) Error!usize {
        const input = self.input;
        var pos = start;
        while (pos + 4 <= self.end) {
            const u = std.mem.readInt(u32, input[pos..][0..4], .little);
            // 3-byte sequence [1110xxxx 10xxxxxx 10xxxxxx], rejecting overlong
            // and surrogate halves.
            if (u & 0x00C0C0F0 == 0x008080E0) {
                const required = u & 0x0000200F;
                if (required == 0 or required == 0x0000200D) return error.InvalidJson;
                pos += 3;
                continue;
            }
            // 2-byte sequence [110xxxxx 10xxxxxx], rejecting overlong C0/C1.
            if (u & 0x0000C0E0 == 0x000080C0) {
                if (u & 0x0000001E == 0) return error.InvalidJson;
                pos += 2;
                continue;
            }
            // 4-byte sequence [11110xxx 10xxxxxx 10xxxxxx 10xxxxxx], restricted
            // to U+10000..U+10FFFF. It is valid when either requirement clears.
            if (u & 0xC0C0C0F8 == 0x808080F0) {
                const required = u & 0x00003007;
                if (required == 0 or (required & 0x04 != 0 and required & 0x00003003 != 0)) {
                    return error.InvalidJson;
                }
                pos += 4;
                continue;
            }
            if (u & 0x80 == 0) return pos;
            return error.InvalidJson;
        }
        // Fewer than four bytes remain: validate one sequence at a time.
        while (pos < self.end) {
            if (input[pos] < 0x80) return pos;
            pos += try self.utf8SequenceLen(pos);
        }
        return pos;
    }

    /// Validates one UTF-8 sequence at `pos` and returns its byte length.
    ///
    /// yyjson validates UTF-8 by default, so this rejects lone continuation
    /// bytes, overlong forms, surrogates, and code points beyond U+10FFFF.
    inline fn utf8SequenceLen(self: *Reader, pos: usize) Error!usize {
        const input = self.input;
        const b0 = input[pos];
        const extra = utf8_continuations[b0];
        if (extra == 0xFF or pos + extra >= self.end) return error.InvalidJson;
        if (input[pos + 1] & 0xC0 != 0x80) return error.InvalidJson;
        if (extra == 1) return 2;
        if (input[pos + 2] & 0xC0 != 0x80) return error.InvalidJson;
        if (extra == 2) {
            const b1 = input[pos + 1];
            if (b0 == 0xE0 and b1 < 0xA0) return error.InvalidJson;
            if (b0 == 0xED and b1 >= 0xA0) return error.InvalidJson;
            return 3;
        }
        if (input[pos + 3] & 0xC0 != 0x80) return error.InvalidJson;
        const b1 = input[pos + 1];
        if (b0 == 0xF0 and b1 < 0x90) return error.InvalidJson;
        if (b0 == 0xF4 and b1 >= 0x90) return error.InvalidJson;
        return 4;
    }

    /// Decodes `\uXXXX`, including surrogate pairs, into UTF-8 at `write`.
    fn readUnicodeEscape(self: *Reader, start: usize, write: usize) Error!Escape {
        var pos = start;
        var codepoint: u21 = undefined;
        pos = try self.readHex4(pos, &codepoint);
        if (codepoint >= 0xd800 and codepoint <= 0xdbff) {
            if (pos + 2 > self.end or
                self.input[pos] != '\\' or self.input[pos + 1] != 'u')
            {
                return error.InvalidJson;
            }
            pos += 2;
            var low: u21 = undefined;
            pos = try self.readHex4(pos, &low);
            if (low < 0xdc00 or low > 0xdfff) return error.InvalidJson;
            codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00);
        } else if (codepoint >= 0xdc00 and codepoint <= 0xdfff) {
            return error.InvalidJson;
        }

        var bytes: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &bytes) catch return error.InvalidJson;
        @memcpy(self.input[write..][0..len], bytes[0..len]);
        return .{ .pos = pos, .write = write + len };
    }

    fn readHex4(self: *Reader, pos: usize, out: *u21) Error!usize {
        if (pos + 4 > self.end) return error.InvalidJson;
        var value: u21 = 0;
        for (self.input[pos..][0..4]) |byte| {
            const digit: u21 = switch (byte) {
                '0'...'9' => byte - '0',
                'a'...'f' => byte - 'a' + 10,
                'A'...'F' => byte - 'A' + 10,
                else => return error.InvalidJson,
            };
            value = (value << 4) | digit;
        }
        out.* = value;
        return pos + 4;
    }

    /// Appends a value; the common case is inlined and only growth is a call.
    /// Appends a value given as its two words.
    ///
    /// Passing tag and payload separately keeps the 16-byte `Value` out of the
    /// caller's stack frame; building it inline was the hottest instruction
    /// pair in the reader.
    inline fn append(self: *Reader, tag: pool_mod.Tag, uni: pool_mod.Payload) Error!u32 {
        const pool = self.pool;
        if (@as(usize, pool.len) == pool.buffer.len) {
            return pool.append(.{ .tag = tag, .uni = uni }) catch return error.OutOfMemory;
        }
        const index: u32 = @intCast(pool.len);
        const slot = &pool.buffer[pool.len];
        slot.tag = tag;
        slot.uni = uni;
        pool.len += 1;
        return index;
    }

    fn skipTrivia(self: *Reader, start: usize) Error!usize {
        const input = self.input;
        var pos = start;
        if (!self.options.allow_comments) {
            // Every JSON whitespace byte is `<= ' '`, so one comparison rejects
            // the common case of a compact document.
            while (true) {
                const byte = input[pos];
                if (byte > ' ') return pos;
                switch (byte) {
                    ' ', '\t', '\n', '\r' => pos += 1,
                    else => return pos,
                }
            }
        }
        // A zero padding byte is not whitespace, so this always terminates.
        while (true) {
            switch (input[pos]) {
                ' ', '\t', '\n', '\r' => pos += 1,
                '/' => pos = try self.skipComment(pos),
                else => return pos,
            }
        }
    }

    fn skipComment(self: *Reader, start: usize) Error!usize {
        const input = self.input;
        if (start + 1 >= self.end) return error.InvalidJson;
        const kind = input[start + 1];
        var pos = start + 2;
        if (kind == '/') {
            while (pos < self.end and input[pos] != '\n' and input[pos] != '\r') pos += 1;
            return pos;
        }
        if (kind != '*') return error.InvalidJson;
        while (pos + 1 < self.end) : (pos += 1) {
            if (input[pos] == '*' and input[pos + 1] == '/') return pos + 2;
        }
        return error.InvalidJson;
    }
};

/// Test helper: pads `input`, parses it, and hands back the buffer whose bytes
/// string offsets refer to.
fn readWithOptions(input: []u8, options: Options, allocator: std.mem.Allocator) !struct { Pool, u32, []u8 } {
    const buffer = try allocator.alloc(u8, input.len + 4);
    errdefer allocator.free(buffer);
    @memcpy(buffer[0..input.len], input);
    @memset(buffer[input.len..], 0);

    var pool = try Pool.init(allocator, input.len, false);
    errdefer pool.deinit();
    const root = try read(&pool, buffer, input.len, options);
    return .{ pool, root, buffer };
}

test "nested values" {
    var input = "{\"items\":[1,{\"ok\":true}],\"name\":\"json\"}".*;
    var result = try readWithOptions(&input, .{}, std.testing.allocator);
    defer result[0].deinit();
    defer std.testing.allocator.free(result[2]);
    const pool = &result[0];
    try std.testing.expectEqual(Type.object, pool_mod.valueType(pool.at(result[1]).*));
    try std.testing.expectEqual(@as(usize, 2), pool_mod.valueLen(pool.at(result[1]).*));
    // 1 root object + 2 keys + 2 values (array, string) + 3 array items =
    // 9 values, keys included.
    try std.testing.expectEqual(@as(usize, 9), pool.items().len);
}

test "trailing comma" {
    var input = "[1,]".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&input, .{}, std.testing.allocator));
    var allowed = "[1,]".*;
    var result = try readWithOptions(&allowed, .{ .allow_trailing_commas = true }, std.testing.allocator);
    defer result[0].deinit();
    defer std.testing.allocator.free(result[2]);
}

test "comments" {
    var input = "/* lead */ {\"a\": 1 // tail\n}".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&input, .{}, std.testing.allocator));
    var result = try readWithOptions(&input, .{ .allow_comments = true }, std.testing.allocator);
    defer result[0].deinit();
    defer std.testing.allocator.free(result[2]);
    try std.testing.expectEqual(@as(usize, 3), result[0].items().len);
}

test "unicode escapes" {
    const cases = .{
        .{ "\"\\u0041\"", "A" },
        .{ "\"\\u00e9\"", "\u{e9}" },
        .{ "\"\\u4e2d\"", "\u{4e2d}" },
        .{ "\"\\uD83D\\uDE00\"", "\u{1f600}" },
        .{ "\"\\u0000\"", "\x00" },
    };
    inline for (cases) |case| {
        var input = case[0].*;
        var result = try readWithOptions(&input, .{}, std.testing.allocator);
        defer result[0].deinit();
        defer std.testing.allocator.free(result[2]);
        const value = result[0].at(result[1]).*;
        try std.testing.expectEqualStrings(
            case[1],
            result[2][@intCast(value.uni.offset)..][0..pool_mod.valueLen(value)],
        );
    }
}

test "invalid unicode escapes" {
    var lone_high = "\"\\uD800\"".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&lone_high, .{}, std.testing.allocator));
    var lone_low = "\"\\uDC00\"".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&lone_low, .{}, std.testing.allocator));
    var bad = "\"\\uZZZZ\"".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&bad, .{}, std.testing.allocator));
}

test "invalid UTF-8 in strings" {
    var invalid_lead = "\"\xff\"".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&invalid_lead, .{}, std.testing.allocator));
    var overlong = "\"\xc0\x80\"".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&overlong, .{}, std.testing.allocator));
    var surrogate = "\"\xed\xa0\x80\"".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&surrogate, .{}, std.testing.allocator));
    var truncated = "\"\xc2\"".*;
    try std.testing.expectError(error.InvalidJson, readWithOptions(&truncated, .{}, std.testing.allocator));

    var valid = "\"\xe4\xb8\xad\"".*;
    var result = try readWithOptions(&valid, .{}, std.testing.allocator);
    defer result[0].deinit();
    defer std.testing.allocator.free(result[2]);
}

test "number subtypes" {
    const Case = struct { text: []const u8, subtype: Subtype, bits: u64 };
    const cases = [_]Case{
        .{ .text = "0", .subtype = pool_mod.uint, .bits = 0 },
        .{ .text = "-0", .subtype = pool_mod.sint, .bits = 0 },
        .{ .text = "42", .subtype = pool_mod.uint, .bits = 42 },
        .{ .text = "-42", .subtype = pool_mod.sint, .bits = @bitCast(@as(i64, -42)) },
        .{ .text = "18446744073709551615", .subtype = pool_mod.uint, .bits = std.math.maxInt(u64) },
        // Values beyond the integer range become doubles.
        .{ .text = "18446744073709551616", .subtype = .real, .bits = @bitCast(@as(f64, 18446744073709551616)) },
        .{ .text = "-9223372036854775808", .subtype = pool_mod.sint, .bits = @bitCast(@as(i64, std.math.minInt(i64))) },
        .{ .text = "1.5", .subtype = .real, .bits = @bitCast(@as(f64, 1.5)) },
        .{ .text = "1e3", .subtype = .real, .bits = @bitCast(@as(f64, 1000)) },
    };
    inline for (cases) |case| {
        var result = try readWithOptions(@constCast(case.text), .{}, std.testing.allocator);
        defer result[0].deinit();
        defer std.testing.allocator.free(result[2]);
        const value = result[0].at(result[1]).*;
        try std.testing.expectEqual(Type.number, pool_mod.valueType(value));
        try std.testing.expectEqual(case.subtype, pool_mod.valueSubtype(value));
        try std.testing.expectEqual(case.bits, value.uni.uint);
    }
}

test "invalid numbers" {
    const cases = [_][]const u8{
        "01", "-", "1.", ".1", "1e", "1e+", "+1", "1e309",
    };
    for (cases) |case| {
        try std.testing.expectError(
            error.InvalidJson,
            readWithOptions(@constCast(case), .{}, std.testing.allocator),
        );
    }
}
