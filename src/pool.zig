const std = @import("std");

const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const Pool = struct {
    fixed_buffer: std.heap.FixedBufferAllocator,
    fallback_allocator: Allocator,

    pub fn init(buffer: []u8, fallback: Allocator) Pool {
        return .{
            .fixed_buffer = .init(buffer),
            .fallback_allocator = fallback,
        };
    }

    pub fn allocator(self: *Pool) Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: Alignment, return_address: usize) ?[*]u8 {
        const self: *Pool = @ptrCast(@alignCast(context));
        return std.heap.FixedBufferAllocator.alloc(&self.fixed_buffer, len, alignment, return_address) orelse
            self.fallback_allocator.rawAlloc(len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *Pool = @ptrCast(@alignCast(context));
        if (self.fixed_buffer.ownsPtr(memory.ptr)) {
            return std.heap.FixedBufferAllocator.resize(&self.fixed_buffer, memory, alignment, new_len, return_address);
        }
        return self.fallback_allocator.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *Pool = @ptrCast(@alignCast(context));
        if (self.fixed_buffer.ownsPtr(memory.ptr)) {
            return std.heap.FixedBufferAllocator.remap(&self.fixed_buffer, memory, alignment, new_len, return_address);
        }
        return self.fallback_allocator.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: Alignment, return_address: usize) void {
        const self: *Pool = @ptrCast(@alignCast(context));
        if (self.fixed_buffer.ownsPtr(memory.ptr)) {
            return std.heap.FixedBufferAllocator.free(&self.fixed_buffer, memory, alignment, return_address);
        }
        self.fallback_allocator.rawFree(memory, alignment, return_address);
    }
};
