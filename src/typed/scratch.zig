//! Remembers the allocations a borrowed parse makes, so a failure can release
//! all of them.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

/// Wraps `backing` and tracks every live allocation made through `allocator`.
///
/// `releaseAll` frees them; `deinit` drops the bookkeeping and leaves them to
/// the caller.
pub const Scratch = struct {
    backing: Allocator,
    live: std.AutoHashMapUnmanaged(usize, Entry) = .{},

    const Entry = struct {
        len: usize,
        alignment: Alignment,
    };

    pub fn allocator(self: *Scratch) Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Frees everything allocated through `allocator`.
    pub fn releaseAll(self: *Scratch) void {
        var entries = self.live.iterator();
        while (entries.next()) |entry| {
            self.backing.rawFree(
                @as([*]u8, @ptrFromInt(entry.key_ptr.*))[0..entry.value_ptr.len],
                entry.value_ptr.alignment,
                0,
            );
        }
        self.live.clearAndFree(self.backing);
        self.live = .{};
    }

    /// Drops the bookkeeping and leaves the allocations to the caller.
    pub fn deinit(self: *Scratch) void {
        self.live.deinit(self.backing);
        self.live = .{};
    }

    const vtable: Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: Alignment, ret_addr: usize) ?[*]u8 {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live.put(self.backing, @intFromPtr(ptr), .{ .len = len, .alignment = alignment }) catch {
            self.backing.rawFree(ptr[0..len], alignment, ret_addr);
            return null;
        };
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (self.live.getPtr(@intFromPtr(memory.ptr))) |entry| entry.len = new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        const ptr = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (self.live.fetchRemove(@intFromPtr(memory.ptr))) |removed| {
            self.live.putAssumeCapacity(
                @intFromPtr(ptr),
                .{ .len = new_len, .alignment = removed.value.alignment },
            );
        }
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: Alignment, ret_addr: usize) void {
        const self: *Scratch = @ptrCast(@alignCast(ctx));
        _ = self.live.remove(@intFromPtr(memory.ptr));
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "releaseAll frees allocations" {
    var scratch: Scratch = .{ .backing = std.testing.allocator };
    const bytes = try scratch.allocator().alloc(u8, 16);
    const words = try scratch.allocator().alloc(u32, 8);
    _ = bytes;
    _ = words;
    try std.testing.expectEqual(@as(usize, 2), scratch.live.count());
    scratch.releaseAll();
    try std.testing.expectEqual(@as(usize, 0), scratch.live.count());
}

test "releaseAll frees resized allocations" {
    var scratch: Scratch = .{ .backing = std.testing.allocator };
    const allocator = scratch.allocator();
    var list: std.ArrayList(u8) = .empty;
    try list.appendSlice(allocator, "0123456789");
    try list.appendSlice(allocator, "0123456789");
    scratch.releaseAll();
}

test "deinit keeps allocations" {
    var scratch: Scratch = .{ .backing = std.testing.allocator };
    const bytes = try scratch.allocator().alloc(u8, 8);
    scratch.deinit();
    std.testing.allocator.free(bytes);
}
