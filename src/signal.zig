//! Lets any thread, including another PHP thread, block until a server publishes events.
//! PHP only holds a numeric handle, checked against this registry, so a stale or forged one is refused.
const std = @import("std");

pub const Signal = struct {
    sequence: std.atomic.Value(u32) = .init(0),
    waiters: std.atomic.Value(u32) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),
    /// The owning server holds one reference and every wait in progress another.
    references: u32 = 1,

    pub fn notify(self: *Signal) void {
        _ = self.sequence.fetchAdd(1, .seq_cst);
        if (self.waiters.load(.seq_cst) != 0) io().futexWake(u32, &self.sequence.raw, std.math.maxInt(u32));
    }
};

const capacity = 64;

var lock: std.atomic.Value(bool) = .init(false);
var entries: [capacity]struct { signal: ?*Signal = null, generation: u32 = 0 } = @splat(.{});

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn acquireLock() void {
    while (lock.swap(true, .acquire)) std.atomic.spinLoopHint();
}

fn releaseLock() void {
    lock.store(false, .release);
}

/// Returns the signal and its handle, or null when every slot is taken.
pub fn create() ?struct { signal: *Signal, handle: u64 } {
    const signal = std.heap.c_allocator.create(Signal) catch return null;
    signal.* = .{};
    acquireLock();
    defer releaseLock();
    for (&entries, 0..) |*entry, index| {
        if (entry.signal != null) continue;
        entry.generation +%= 1;
        if (entry.generation == 0) entry.generation = 1;
        entry.signal = signal;
        return .{ .signal = signal, .handle = @as(u64, entry.generation) << 8 | index };
    }
    std.heap.c_allocator.destroy(signal);
    return null;
}

/// Called by the owner when it goes away: waiters return at once and the memory goes with the last reference.
pub fn close(signal: *Signal) void {
    acquireLock();
    for (&entries) |*entry| {
        if (entry.signal == signal) entry.signal = null;
    }
    signal.closed.store(true, .seq_cst);
    signal.references -= 1;
    const last = signal.references == 0;
    releaseLock();
    signal.notify();
    if (last) std.heap.c_allocator.destroy(signal);
}

/// Blocks until the sequence differs from `seen`, the timeout passes or the signal closes.
/// Returns the current sequence, or null for an unknown or closed handle.
pub fn wait(handle: u64, seen: u32, timeout_ms: u32) ?u32 {
    const index = handle & 0xff;
    if (index >= capacity) return null;
    acquireLock();
    const entry = &entries[@intCast(index)];
    const signal = entry.signal orelse {
        releaseLock();
        return null;
    };
    if (entry.generation != handle >> 8) {
        releaseLock();
        return null;
    }
    signal.references += 1;
    releaseLock();

    _ = signal.waiters.fetchAdd(1, .seq_cst);
    if (!signal.closed.load(.seq_cst) and signal.sequence.load(.seq_cst) == seen) {
        io().futexWaitTimeout(u32, &signal.sequence.raw, seen, .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } }) catch {};
    }
    _ = signal.waiters.fetchSub(1, .seq_cst);
    const sequence = signal.sequence.load(.seq_cst);
    const closed = signal.closed.load(.seq_cst);

    acquireLock();
    signal.references -= 1;
    const last = signal.references == 0;
    releaseLock();
    if (last) std.heap.c_allocator.destroy(signal);
    return if (closed) null else sequence;
}

const testing = std.testing;

test "waits wake on notify and end when the owner closes" {
    const created = create().?;
    try testing.expectEqual(@as(?u32, 0), wait(created.handle, 1, 0));
    created.signal.notify();
    try testing.expectEqual(@as(?u32, 1), wait(created.handle, 0, 1000));

    const Waiter = struct {
        fn run(handle: u64, result: *?u32) void {
            result.* = wait(handle, 1, 10_000);
        }
    };
    var result: ?u32 = 7;
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{ created.handle, &result });
    while (created.signal.waiters.load(.seq_cst) == 0) std.atomic.spinLoopHint();
    close(created.signal);
    thread.join();
    try testing.expectEqual(@as(?u32, null), result);
    try testing.expectEqual(@as(?u32, null), wait(created.handle, 0, 0));
    try testing.expectEqual(@as(?u32, null), wait(12345, 0, 0));
}
