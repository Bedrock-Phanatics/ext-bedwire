const std = @import("std");
const raknet = @import("raknet");

const Ring = @import("ring.zig").Ring;
const Worker = @import("worker.zig").Worker;
const address_mod = @import("address.zig");

pub const Event = enum(u32) { connect = 1, disconnect, packet, receipt_ack, receipt_failed, ping, raw };
pub const Command = enum(u32) { send = 1, disconnect, encrypt, accept_login, advertise, block, unblock, raw_send };
pub const Reason = enum(u8) { remote, server, protocol, overload, shutdown };

pub const max_sessions_limit = 1 << 16;
/// Largest RakNet message, so the largest Bedrock frame.
pub const max_frame_bytes = 4 * 1024 * 1024;
pub const max_packets_per_batch = 1024;
pub const key_len = 32;

pub const Config = struct {
    address: std.Io.net.IpAddress,
    advertisement: []const u8,
    guid: u64 = 0,
    max_sessions: u32 = 1024,
    encryption: bool = true,
    command_queue_bytes: usize = 16 * 1024 * 1024,
    event_queue_bytes: usize = 16 * 1024 * 1024,
    max_batch_bytes: usize = 4 * 1024 * 1024,
    /// Inbound game packets per session per second; 0 disables the limit.
    packet_rate: u32 = 2000,
    ping_interval_ms: u32 = 2000,
    max_receipts: u32 = 4096,
    max_blocked: u32 = 4096,
    raw_prefixes: []const []const u8 = &.{},
    raw_rate: u32 = 1000,
    /// Offline handshake datagrams per source IP per second; raise it behind a proxy.
    handshake_rate: u32 = 20,

    pub const max_raw_prefixes = 8;
    pub const max_raw_prefix_len = 16;

    pub fn validate(self: Config) !void {
        if (self.max_sessions == 0 or self.max_sessions >= max_sessions_limit) return error.InvalidConfig;
        if (self.advertisement.len == 0 or self.advertisement.len > 1400) return error.InvalidConfig;
        if (self.max_batch_bytes < 64 * 1024 or self.max_batch_bytes > 64 * 1024 * 1024) return error.InvalidConfig;
        if (self.command_queue_bytes < 1024 * 1024 or self.command_queue_bytes > 1 << 30) return error.InvalidConfig;
        if (self.event_queue_bytes < 2 * (self.max_batch_bytes + 64) or self.event_queue_bytes > 1 << 30) return error.InvalidConfig;
        if (self.max_receipts == 0 or self.max_receipts > 1 << 20) return error.InvalidConfig;
        if (self.max_blocked > 1 << 20) return error.InvalidConfig;
        if (self.ping_interval_ms < 100) return error.InvalidConfig;
        if (self.handshake_rate == 0 or self.handshake_rate > 1_000_000) return error.InvalidConfig;
        if (self.raw_prefixes.len > max_raw_prefixes) return error.InvalidConfig;
        for (self.raw_prefixes) |prefix| if (prefix.len == 0 or prefix.len > max_raw_prefix_len) return error.InvalidConfig;
        const reserve = (@as(usize, self.max_sessions) + self.max_receipts) * Worker.obligation_bytes;
        if (reserve > self.event_queue_bytes / 4) return error.InvalidConfig;
    }
};

/// Worker counters mirrored for the PHP thread; values may lag by one turn.
pub const Statistics = struct {
    sessions: u64 = 0,
    bytes_sent: u64 = 0,
    bytes_received: u64 = 0,
    datagrams_sent: u64 = 0,
    datagrams_received: u64 = 0,
    packets_received: u64 = 0,
    batches_sent: u64 = 0,
    packets_rejected: u64 = 0,
    overload_disconnects: u64 = 0,
    protocol_disconnects: u64 = 0,
    connections_refused: u64 = 0,
    raw_dropped: u64 = 0,
    blocked_dropped: u64 = 0,
    transport_errors: u64 = 0,
};

pub const stat_names = std.meta.fieldNames(Statistics);

pub const Shared = struct {
    commands: Ring,
    events: Ring,
    /// Generation per slot while the session is live, else 0.
    live: []std.atomic.Value(u32),
    stats: [stat_names.len]std.atomic.Value(u64),

    sleeping: std.atomic.Value(bool) = .init(false),
    wants_events_space: std.atomic.Value(bool) = .init(false),
    consumer_waiting: std.atomic.Value(bool) = .init(false),
    event_seq: std.atomic.Value(u32) = .init(0),
    stop_requested: std.atomic.Value(bool) = .init(false),
    stop_timeout_ms: std.atomic.Value(u32) = .init(0),
    exited: std.atomic.Value(bool) = .init(false),
    /// For profilers; zero until the worker starts.
    worker_thread: std.atomic.Value(u64) = .init(0),
    wake_token: [16]u8,

    pub fn storeStats(self: *Shared, stats: Statistics) void {
        inline for (stat_names, 0..) |name, i| self.stats[i].store(@field(stats, name), .monotonic);
    }

    pub fn loadStats(self: *const Shared) Statistics {
        var stats: Statistics = .{};
        inline for (stat_names, 0..) |name, i| @field(stats, name) = self.stats[i].load(.monotonic);
        return stats;
    }

    pub fn notifyConsumer(self: *Shared, io: std.Io) void {
        if (!self.consumer_waiting.load(.seq_cst)) return;
        _ = self.event_seq.fetchAdd(1, .seq_cst);
        io.futexWake(u32, &self.event_seq.raw, 1);
    }
};

pub fn sessionId(index: u32, generation: u32) u64 {
    return (@as(u64, generation) << 16) | index;
}

pub fn sessionParts(id: u64) ?struct { index: u32, generation: u32 } {
    const generation = std.math.cast(u32, id >> 16) orelse return null;
    if (generation == 0) return null;
    return .{ .index = @intCast(id & 0xffff), .generation = generation };
}

pub const Delivered = union(Event) {
    connect: struct { session: u64, address: []const u8, port: u16, guid: u64 },
    disconnect: struct { session: u64, reason: Reason },
    packet: struct { session: u64, bytes: []const u8 },
    receipt_ack: struct { session: u64, receipt: u64 },
    receipt_failed: struct { session: u64, receipt: u64 },
    ping: struct { session: u64, rtt_ms: u64 },
    raw: struct { address: []const u8, port: u16, bytes: []const u8 },
};

pub const SendError = error{ Closed, Backpressure, TooLarge, TooManyPackets, EmptyBatch };

/// Owned by one PHP thread. The worker never touches Zend memory; everything
/// handed to it is copied into the command ring before a call returns.
pub const Host = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    shared: Shared,
    config: Config,
    worker: *Worker,
    thread: ?std.Thread = null,
    wake_socket: std.Io.net.Socket,
    wake_target: std.Io.net.IpAddress,
    local_address: std.Io.net.IpAddress,
    next_receipt: u64 = 1,
    receipts_pending: usize = 0,
    stopped: bool = false,

    pub fn start(allocator: std.mem.Allocator, config: Config) !*Host {
        try config.validate();

        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .threaded = std.Io.Threaded.init_single_threaded,
            .shared = undefined,
            .config = config,
            .worker = undefined,
            .wake_socket = undefined,
            .wake_target = undefined,
            .local_address = undefined,
        };
        self.threaded.allocator = allocator;
        const threaded_io = self.threaded.io();

        var commands = try Ring.init(allocator, config.command_queue_bytes);
        errdefer commands.deinit(allocator);
        var events = try Ring.init(allocator, config.event_queue_bytes);
        errdefer events.deinit(allocator);
        const live = try allocator.alloc(std.atomic.Value(u32), config.max_sessions);
        errdefer allocator.free(live);
        @memset(live, .init(0));

        self.shared = .{
            .commands = commands,
            .events = events,
            .live = live,
            .stats = undefined,
            .wake_token = undefined,
        };
        @memset(&self.shared.stats, .init(0));
        threaded_io.random(&self.shared.wake_token);

        self.worker = try Worker.create(allocator, threaded_io, &self.shared, &self.config);
        errdefer self.worker.destroy();
        self.local_address = self.worker.listener.localAddress();

        self.wake_target = address_mod.reachable(self.local_address);
        const bind: std.Io.net.IpAddress = switch (self.wake_target) {
            .ip4 => .{ .ip4 = .unspecified(0) },
            .ip6 => .{ .ip6 = .unspecified(0) },
        };
        self.wake_socket = try bind.bind(threaded_io, .{ .mode = .dgram, .protocol = .udp });
        errdefer self.wake_socket.close(threaded_io);

        self.thread = try std.Thread.spawn(.{ .stack_size = 1024 * 1024 }, Worker.run, .{self.worker});
        return self;
    }

    pub fn io(self: *Host) std.Io {
        return self.threaded.io();
    }

    pub fn running(self: *const Host) bool {
        return !self.stopped and !self.shared.exited.load(.acquire);
    }

    /// Idempotent. Lets sessions close gracefully for up to timeout_ms, then
    /// forces the rest closed and joins the worker. Remaining events stay drainable.
    pub fn stop(self: *Host, timeout_ms: u32) void {
        if (self.stopped) return;
        self.stopped = true;
        self.shared.stop_timeout_ms.store(timeout_ms, .monotonic);
        self.shared.stop_requested.store(true, .seq_cst);
        self.wakeWorker(true);
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.worker.destroy();
        self.wake_socket.close(self.io());
    }

    pub fn destroy(self: *Host) void {
        self.stop(0);
        const allocator = self.allocator;
        self.shared.commands.deinit(allocator);
        self.shared.events.deinit(allocator);
        allocator.free(self.shared.live);
        allocator.destroy(self);
    }

    pub fn statistics(self: *const Host) Statistics {
        return self.shared.loadStats();
    }

    pub fn isLive(self: *const Host, session: u64) bool {
        const parts = sessionParts(session) orelse return false;
        if (parts.index >= self.shared.live.len) return false;
        return self.shared.live[parts.index].load(.acquire) == parts.generation;
    }

    pub fn maxBatchPayload(self: *const Host) usize {
        return @min(self.config.max_batch_bytes, max_frame_bytes - 64, self.shared.commands.maxRecord() - 64);
    }

    /// Returns the receipt ID when requested. Packets keep their order and share one frame.
    pub fn send(self: *Host, session: u64, packets: []const []const u8, receipt: bool) SendError!u64 {
        if (packets.len == 0) return error.EmptyBatch;
        if (packets.len > max_packets_per_batch) return error.TooManyPackets;
        var total: usize = 0;
        for (packets) |packet| {
            if (packet.len == 0) return error.EmptyBatch;
            total += 4 + packet.len;
        }
        if (total > self.maxBatchPayload()) return error.TooLarge;
        if (!self.running() or !self.isLive(session)) return error.Closed;
        if (receipt and self.receipts_pending >= self.config.max_receipts) return error.Backpressure;

        const id: u64 = if (receipt) self.next_receipt else 0;
        const bytes = self.reserve(.send, 16 + total) orelse return error.Backpressure;
        std.mem.writeInt(u64, bytes[0..8], session, .little);
        std.mem.writeInt(u64, bytes[8..16], id, .little);
        var offset: usize = 16;
        for (packets) |packet| {
            std.mem.writeInt(u32, bytes[offset..][0..4], @intCast(packet.len), .little);
            @memcpy(bytes[offset + 4 ..][0..packet.len], packet);
            offset += 4 + packet.len;
        }
        self.submit();
        if (receipt) {
            self.next_receipt += 1;
            self.receipts_pending += 1;
        }
        return id;
    }

    pub fn disconnect(self: *Host, session: u64) SendError!void {
        return self.sessionCommand(.disconnect, session, &.{}, &.{});
    }

    /// Sends the cleartext ServerToClientHandshake, then encrypts everything after it.
    pub fn enableEncryption(self: *Host, session: u64, handshake: []const u8, key: *const [key_len]u8) SendError!void {
        if (handshake.len == 0) return error.EmptyBatch;
        if (handshake.len > self.maxBatchPayload()) return error.TooLarge;
        return self.sessionCommand(.encrypt, session, key, handshake);
    }

    /// For servers without encryption: the client key PHP verified from the login chain, as DER.
    pub fn acceptLogin(self: *Host, session: u64, client_key_der: []const u8) SendError!void {
        if (client_key_der.len == 0 or client_key_der.len > 512) return error.TooLarge;
        return self.sessionCommand(.accept_login, session, client_key_der, &.{});
    }

    pub fn setAdvertisement(self: *Host, advertisement: []const u8) SendError!void {
        if (advertisement.len == 0 or advertisement.len > 1400) return error.TooLarge;
        return self.globalCommand(.advertise, &.{}, advertisement);
    }

    pub fn blockAddress(self: *Host, address: std.Io.net.IpAddress, seconds: u32) SendError!void {
        var head: [8]u8 = undefined;
        std.mem.writeInt(u64, &head, @as(u64, seconds) * 1000, .little);
        const key = address_mod.key(address);
        return self.globalCommand(.block, &head, &key);
    }

    pub fn unblockAddress(self: *Host, address: std.Io.net.IpAddress) SendError!void {
        const key = address_mod.key(address);
        return self.globalCommand(.unblock, &.{}, &key);
    }

    pub fn sendRaw(self: *Host, address: std.Io.net.IpAddress, payload: []const u8) SendError!void {
        if (payload.len == 0 or payload.len > 1400) return error.TooLarge;
        return self.globalCommand(.raw_send, std.mem.asBytes(&address), payload);
    }

    /// Decoded view into the event ring. Valid until releaseEvents.
    pub fn nextEvent(self: *Host) ?Delivered {
        const record = self.shared.events.next() orelse return null;
        const bytes = record.bytes;
        const session = std.mem.readInt(u64, bytes[0..8], .little);
        const event: Delivered = switch (@as(Event, @fromBackingInt(@intCast(record.tag)))) {
            .packet => .{ .packet = .{ .session = session, .bytes = bytes[8..] } },
            .connect => .{ .connect = .{
                .session = session,
                .guid = std.mem.readInt(u64, bytes[8..16], .little),
                .port = std.mem.readInt(u16, bytes[16..18], .little),
                .address = bytes[18..],
            } },
            .disconnect => .{ .disconnect = .{ .session = session, .reason = @fromBackingInt(@intCast(bytes[8])) } },
            .receipt_ack => .{ .receipt_ack = .{ .session = session, .receipt = std.mem.readInt(u64, bytes[8..16], .little) } },
            .receipt_failed => .{ .receipt_failed = .{ .session = session, .receipt = std.mem.readInt(u64, bytes[8..16], .little) } },
            .ping => .{ .ping = .{ .session = session, .rtt_ms = std.mem.readInt(u64, bytes[8..16], .little) } },
            .raw => .{ .raw = .{
                .port = @intCast(session & 0xffff),
                .address = bytes[16..][0..std.mem.readInt(u64, bytes[8..16], .little)],
                .bytes = bytes[16 + std.mem.readInt(u64, bytes[8..16], .little) ..],
            } },
        };
        switch (event) {
            .receipt_ack, .receipt_failed => self.receipts_pending -= 1,
            else => {},
        }
        return event;
    }

    pub fn releaseEvents(self: *Host) void {
        self.shared.events.release();
        if (self.shared.wants_events_space.swap(false, .seq_cst)) self.wakeWorker(true);
    }

    /// Waits until an event is queued, the worker exits, or the timeout passes.
    pub fn waitEvents(self: *Host, timeout_ms: u32) void {
        if (timeout_ms == 0 or !self.shared.events.isEmpty()) return;
        const seq = self.shared.event_seq.load(.seq_cst);
        self.shared.consumer_waiting.store(true, .seq_cst);
        defer self.shared.consumer_waiting.store(false, .seq_cst);
        if (!self.shared.events.isEmpty() or self.shared.exited.load(.seq_cst)) return;
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } };
        self.io().futexWaitTimeout(u32, &self.shared.event_seq.raw, seq, timeout) catch {};
    }

    fn sessionCommand(self: *Host, kind: Command, session: u64, head: []const u8, tail: []const u8) SendError!void {
        if (!self.running() or !self.isLive(session)) return error.Closed;
        const bytes = self.reserve(kind, 8 + head.len + tail.len) orelse return error.Backpressure;
        std.mem.writeInt(u64, bytes[0..8], session, .little);
        @memcpy(bytes[8..][0..head.len], head);
        @memcpy(bytes[8 + head.len ..][0..tail.len], tail);
        self.submit();
    }

    fn globalCommand(self: *Host, kind: Command, head: []const u8, tail: []const u8) SendError!void {
        if (!self.running()) return error.Closed;
        const bytes = self.reserve(kind, head.len + tail.len) orelse return error.Backpressure;
        @memcpy(bytes[0..head.len], head);
        @memcpy(bytes[head.len..][0..tail.len], tail);
        self.submit();
    }

    fn reserve(self: *Host, kind: Command, len: usize) ?[]u8 {
        return self.shared.commands.reserve(@backingInt(kind), len, 0);
    }

    fn submit(self: *Host) void {
        self.shared.commands.commit();
        self.shared.commands.publish();
        self.wakeWorker(false);
    }

    fn wakeWorker(self: *Host, force: bool) void {
        if (!self.shared.sleeping.swap(false, .seq_cst) and !force) return;
        if (self.thread == null) return;
        self.wake_socket.send(self.io(), &self.wake_target, &self.shared.wake_token) catch {};
    }
};
