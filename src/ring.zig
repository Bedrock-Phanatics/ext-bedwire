const std = @import("std");

/// Bounded single-producer single-consumer queue of variable-length records.
/// Records are contiguous and 8-byte aligned; a record that would straddle the
/// end of the buffer is preceded by padding. The producer publishes a batch of
/// committed records at once and the consumer releases a batch at once.
pub const Ring = struct {
    storage: []align(8) u8,
    mask: u64,

    tail: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
    producer_tail: u64 = 0,
    producer_head: u64 = 0,
    pending: u64 = 0,

    head: std.atomic.Value(u64) align(std.atomic.cache_line) = .init(0),
    consumer_head: u64 = 0,
    consumer_tail: u64 = 0,

    const header_len = 8;
    const pad_tag = std.math.maxInt(u32);

    pub const Record = struct { tag: u32, bytes: []u8 };

    pub fn init(allocator: std.mem.Allocator, capacity: usize) !Ring {
        if (capacity < 64 or capacity > 1 << 31) return error.InvalidCapacity;
        const size = std.math.ceilPowerOfTwo(usize, capacity) catch return error.InvalidCapacity;
        const storage = try allocator.alignedAlloc(u8, .@"8", size);
        return .{ .storage = storage, .mask = size - 1 };
    }

    pub fn deinit(self: *Ring, allocator: std.mem.Allocator) void {
        allocator.free(self.storage);
        self.* = undefined;
    }

    /// Largest payload that can ever be reserved.
    pub fn maxRecord(self: *const Ring) usize {
        return self.storage.len / 2 - header_len;
    }

    pub fn recordSize(len: usize) usize {
        return header_len + std.mem.alignForward(usize, len, 8);
    }

    /// Returns writable payload space, or null if fewer than `keep_free`
    /// bytes would remain afterwards. Nothing is visible until commit and publish.
    pub fn reserve(self: *Ring, tag: u32, len: usize, keep_free: usize) ?[]u8 {
        std.debug.assert(tag != pad_tag);
        if (len > self.maxRecord()) return null;
        const size = recordSize(len);
        const offset = self.producer_tail & self.mask;
        const contiguous = self.storage.len - offset;
        const padding: u64 = if (size > contiguous) contiguous else 0;
        const needed = padding + size + keep_free;

        if (self.free() < needed) {
            self.producer_head = self.head.load(.acquire);
            if (self.free() < needed) return null;
        }

        if (padding != 0) self.writeHeader(offset, pad_tag, 0);
        const start = (self.producer_tail + padding) & self.mask;
        self.writeHeader(start, tag, @intCast(len));
        self.pending = padding + size;
        return self.storage[start + header_len ..][0..len];
    }

    pub fn commit(self: *Ring) void {
        self.producer_tail += self.pending;
        self.pending = 0;
    }

    pub fn publish(self: *Ring) void {
        self.tail.store(self.producer_tail, .seq_cst);
    }

    pub fn free(self: *const Ring) u64 {
        return self.storage.len - (self.producer_tail - self.producer_head);
    }

    pub fn next(self: *Ring) ?Record {
        while (true) {
            if (self.consumer_head == self.consumer_tail) {
                self.consumer_tail = self.tail.load(.acquire);
                if (self.consumer_head == self.consumer_tail) return null;
            }
            const offset = self.consumer_head & self.mask;
            const tag = std.mem.readInt(u32, self.storage[offset..][0..4], .little);
            const len = std.mem.readInt(u32, self.storage[offset + 4 ..][0..4], .little);
            if (tag == pad_tag) {
                self.consumer_head += self.storage.len - offset;
                continue;
            }
            self.consumer_head += recordSize(len);
            return .{ .tag = tag, .bytes = self.storage[offset + header_len ..][0..len] };
        }
    }

    pub fn position(self: *const Ring) u64 {
        return self.consumer_head;
    }

    /// Unreads records back to a position taken earlier in the same batch.
    pub fn rewind(self: *Ring, mark: u64) void {
        self.consumer_head = mark;
    }

    /// Producer view of free bytes after refreshing the consumer position.
    pub fn available(self: *Ring) u64 {
        self.producer_head = self.head.load(.seq_cst);
        return self.free();
    }

    /// Returns space for every record read so far; their bytes become invalid.
    pub fn release(self: *Ring) void {
        self.head.store(self.consumer_head, .seq_cst);
    }

    /// Consumer view; may be stale by the time it returns.
    pub fn isEmpty(self: *Ring) bool {
        return self.consumer_head == self.tail.load(.seq_cst);
    }

    pub fn usedBytes(self: *const Ring) u64 {
        return self.tail.load(.monotonic) -% self.head.load(.monotonic);
    }

    fn writeHeader(self: *Ring, offset: u64, tag: u32, len: u32) void {
        std.mem.writeInt(u32, self.storage[offset..][0..4], tag, .little);
        std.mem.writeInt(u32, self.storage[offset + 4 ..][0..4], len, .little);
    }
};

const testing = std.testing;

test "records round trip in order across wraps" {
    var ring = try Ring.init(testing.allocator, 256);
    defer ring.deinit(testing.allocator);

    var produced: u32 = 0;
    var consumed: u32 = 0;
    while (consumed < 2000) {
        while (produced < 2000) {
            const len = produced % 41;
            const bytes = ring.reserve(produced, len, 0) orelse break;
            @memset(bytes, @truncate(produced));
            ring.commit();
            produced += 1;
        }
        ring.publish();
        while (ring.next()) |record| : (consumed += 1) {
            try testing.expectEqual(consumed, record.tag);
            try testing.expectEqual(@as(usize, consumed % 41), record.bytes.len);
            for (record.bytes) |byte| try testing.expectEqual(@as(u8, @truncate(consumed)), byte);
        }
        ring.release();
    }
    try testing.expect(ring.isEmpty());
}

test "uncommitted and unpublished records stay invisible" {
    var ring = try Ring.init(testing.allocator, 128);
    defer ring.deinit(testing.allocator);

    _ = ring.reserve(1, 8, 0).?;
    ring.publish();
    try testing.expectEqual(@as(?Ring.Record, null), ring.next());
    ring.commit();
    try testing.expectEqual(@as(?Ring.Record, null), ring.next());
    ring.publish();
    try testing.expectEqual(@as(u32, 1), ring.next().?.tag);
}

test "reserve enforces capacity, record size and the keep-free margin" {
    var ring = try Ring.init(testing.allocator, 128);
    defer ring.deinit(testing.allocator);

    try testing.expectEqual(@as(?[]u8, null), ring.reserve(0, ring.maxRecord() + 1, 0));
    try testing.expect(ring.reserve(0, 16, 128 - 24) != null);
    try testing.expectEqual(@as(?[]u8, null), ring.reserve(0, 16, 128 - 23));

    var count: usize = 0;
    while (ring.reserve(0, 8, 0) != null) : (count += 1) ring.commit();
    try testing.expectEqual(@as(usize, 8), count);
    ring.publish();
    _ = ring.next().?;
    ring.release();
    try testing.expect(ring.reserve(0, 8, 0) != null);
}

test "threads exchange a million records without loss" {
    var ring = try Ring.init(testing.allocator, 4096);
    defer ring.deinit(testing.allocator);
    const total = 1_000_000;

    const Producer = struct {
        fn run(r: *Ring) void {
            var i: u32 = 0;
            while (i < total) {
                const bytes = r.reserve(i, 4 + i % 13, 0) orelse {
                    r.publish();
                    std.atomic.spinLoopHint();
                    continue;
                };
                std.mem.writeInt(u32, bytes[0..4], i *% 2654435761, .little);
                r.commit();
                if (i % 7 == 0) r.publish();
                i += 1;
            }
            r.publish();
        }
    };
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&ring});
    var expected: u32 = 0;
    while (expected < total) {
        while (ring.next()) |record| : (expected += 1) {
            try testing.expectEqual(expected, record.tag);
            try testing.expectEqual(expected *% 2654435761, std.mem.readInt(u32, record.bytes[0..4], .little));
        }
        ring.release();
        std.atomic.spinLoopHint();
    }
    thread.join();
}
