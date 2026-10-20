const std = @import("std");

threadlocal var arena: ?std.heap.ArenaAllocator = null;

/// Per-thread scratch memory for one call; native allocations never outlive it, and calls do not nest.
pub fn begin() *std.heap.ArenaAllocator {
    if (arena == null) arena = .init(std.heap.c_allocator);
    return &arena.?;
}

pub fn end(state: *std.heap.ArenaAllocator) void {
    _ = state.reset(.{ .retain_with_limit = 256 * 1024 });
}

/// Frees the retained memory, so nothing outlives the request on this thread.
pub fn release() void {
    if (arena) |*state| state.deinit();
    arena = null;
}
