//! The PHP-thread side of the network worker: it submits commands and drains events, and never blocks on the network.
const std = @import("std");
const nethernet = @import("nethernet");

const Ring = @import("ring.zig").Ring;
const Worker = @import("worker.zig").Worker;

pub const Event = enum(u32) { connect = 1, disconnect, packet, login };
pub const Command = enum(u32) { send = 1, disconnect, accept_login };
pub const Reason = enum(u8) { remote, server, protocol, overload, shutdown, authentication, timeout };

pub const max_sessions_limit = 1 << 16;
pub const max_frame_bytes = 4 * 1024 * 1024;
pub const max_packets_per_batch = 1024;
pub const max_status_text = 256;

pub const Config = struct {
    address: std.Io.net.IpAddress,
    max_sessions: u32 = 1024,
    command_queue_bytes: usize = 16 * 1024 * 1024,
    event_queue_bytes: usize = 16 * 1024 * 1024,
    max_batch_bytes: usize = 4 * 1024 * 1024,
    /// Packets a session may send per second, 0 disables the limit.
    packet_rate: u32 = 2000,
    /// Time a connection gets to finish logging in.
    login_timeout_ms: u32 = 10_000,
    stats_interval_ms: u32 = 1000,
    /// Verify client identities against Minecraft's signing keys, both at signaling and at login.
    authentication: bool = true,
    /// Keeps the server identity across restarts so players only confirm it once.
    identity_file: ?[]const u8 = null,
    /// Concurrent WebRTC negotiations, which bounds how many players can be joining at once.
    max_negotiations: u32 = 16,
    http_workers: u32 = 16,
    /// Per connection buffering for received and unsent data.
    receive_queue_bytes: usize = 1024 * 1024,
    send_buffer_bytes: usize = 16 * 1024 * 1024,
    port_range_begin: u16 = 0,
    port_range_end: u16 = 0,
    udp_mux: bool = false,

    pub fn validate(self: Config) !void {
        if (self.max_sessions == 0 or self.max_sessions >= max_sessions_limit) return error.InvalidConfig;
        if (self.max_batch_bytes < 64 * 1024 or self.max_batch_bytes > 64 * 1024 * 1024) return error.InvalidConfig;
        if (self.command_queue_bytes < 1024 * 1024 or self.command_queue_bytes > 1 << 30) return error.InvalidConfig;
        if (self.event_queue_bytes < 2 * (self.max_batch_bytes + 64) or self.event_queue_bytes > 1 << 30) return error.InvalidConfig;
        if (self.stats_interval_ms < 10 or self.login_timeout_ms == 0) return error.InvalidConfig;
        if (self.max_negotiations == 0 or self.max_negotiations > 1024 or self.http_workers == 0 or self.http_workers > 1024) return error.InvalidConfig;
        if (self.receive_queue_bytes < 64 * 1024 or self.receive_queue_bytes > 64 * 1024 * 1024) return error.InvalidConfig;
        if (self.send_buffer_bytes < 256 * 1024 or self.send_buffer_bytes > 256 * 1024 * 1024) return error.InvalidConfig;
        if ((self.port_range_begin == 0) != (self.port_range_end == 0) or self.port_range_begin > self.port_range_end) return error.InvalidConfig;
        const reserve = @as(usize, self.max_sessions) * Worker.obligation_bytes;
        if (reserve > self.event_queue_bytes / 4) return error.InvalidConfig;
    }
};

pub const Statistics = struct {
    sessions: u64 = 0,
    bytes_sent: u64 = 0,
    bytes_received: u64 = 0,
    packets_received: u64 = 0,
    batches_sent: u64 = 0,
    packets_rejected: u64 = 0,
    unreliable_dropped: u64 = 0,
    overload_disconnects: u64 = 0,
    protocol_disconnects: u64 = 0,
    authentication_failures: u64 = 0,
    timeouts: u64 = 0,
    connections_refused: u64 = 0,
    receive_pauses: u64 = 0,
    event_stalls: u64 = 0,
};

pub const stat_names = std.meta.fieldNames(Statistics);

/// What the HTTP signaling endpoint reports to clients asking about the server.
pub const Status = struct {
    io: std.Io = undefined,
    mutex: std.Io.Mutex = .init,
    name: Text = .{},
    level: Text = .{},
    max_players: u32 = 0,
    game_type: i32 = 0,

    pub const Text = struct {
        bytes: [max_status_text]u8 = undefined,
        len: usize = 0,

        pub fn set(self: *Text, value: []const u8) void {
            self.len = @min(value.len, max_status_text);
            @memcpy(self.bytes[0..self.len], value[0..self.len]);
        }

        pub fn slice(self: *const Text) []const u8 {
            return self.bytes[0..self.len];
        }
    };
};

pub const Shared = struct {
    commands: Ring,
    events: Ring,
    live: []std.atomic.Value(u32),
    stats: [stat_names.len]std.atomic.Value(u64),
    /// The worker waits here, and PHP and every connection signal it.
    wakeup: nethernet.Wakeup = .{},
    status: Status = .{},

    wants_events_space: std.atomic.Value(bool) = .init(false),
    consumer_waiting: std.atomic.Value(bool) = .init(false),
    event_seq: std.atomic.Value(u32) = .init(0),
    stop_requested: std.atomic.Value(bool) = .init(false),
    stop_timeout_ms: std.atomic.Value(u32) = .init(0),
    exited: std.atomic.Value(bool) = .init(false),
    worker_thread: std.atomic.Value(u64) = .init(0),

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
    connect: struct { session: u64, address: []const u8, network_id: []const u8, identity: ?[]const u8 },
    disconnect: struct { session: u64, reason: Reason },
    packet: struct { session: u64, bytes: []const u8 },
    login: struct { session: u64, name: []const u8, uuid: []const u8, xuid: []const u8 },
};

pub const SendError = error{ Closed, Backpressure, TooLarge, TooManyPackets, EmptyBatch };

pub const Host = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
    shared: Shared,
    config: Config,
    worker: *Worker,
    thread: ?std.Thread = null,
    local_address: std.Io.net.IpAddress,
    stopped: bool = false,

    pub fn start(allocator: std.mem.Allocator, config: Config) !*Host {
        try config.validate();

        const self = try allocator.create(Host);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .threaded = .init(allocator, .{}),
            .shared = undefined,
            .config = config,
            .worker = undefined,
            .local_address = undefined,
        };
        errdefer self.threaded.deinit();

        var commands = try Ring.init(allocator, config.command_queue_bytes);
        errdefer commands.deinit(allocator);
        var events = try Ring.init(allocator, config.event_queue_bytes);
        errdefer events.deinit(allocator);
        const live = try allocator.alloc(std.atomic.Value(u32), config.max_sessions);
        errdefer allocator.free(live);
        @memset(live, .init(0));

        self.shared = .{ .commands = commands, .events = events, .live = live, .stats = undefined };
        @memset(&self.shared.stats, .init(0));
        self.shared.status.io = self.threaded.io();
        self.shared.status.max_players = config.max_sessions;

        self.worker = try Worker.create(allocator, self.threaded.io(), &self.shared, &self.config);
        errdefer self.worker.destroy();
        self.local_address = self.worker.listener.server.socket.address;
        // The path is only read while the worker starts.
        self.config.identity_file = null;

        self.thread = try std.Thread.spawn(.{ .stack_size = 16 * 1024 * 1024 }, Worker.run, .{self.worker});
        return self;
    }

    pub fn io(self: *Host) std.Io {
        return self.threaded.io();
    }

    pub fn running(self: *const Host) bool {
        return !self.stopped and !self.shared.exited.load(.acquire);
    }

    pub fn stop(self: *Host, timeout_ms: u32) void {
        if (self.stopped) return;
        self.stopped = true;
        self.shared.stop_timeout_ms.store(timeout_ms, .monotonic);
        self.shared.stop_requested.store(true, .seq_cst);
        self.shared.wakeup.signal(self.io());
        if (self.thread) |thread| thread.join();
        self.thread = null;
        self.worker.destroy();
    }

    pub fn destroy(self: *Host) void {
        self.stop(0);
        const allocator = self.allocator;
        self.shared.commands.deinit(allocator);
        self.shared.events.deinit(allocator);
        allocator.free(self.shared.live);
        self.threaded.deinit();
        allocator.destroy(self);
    }

    pub fn statistics(self: *const Host) Statistics {
        return self.shared.loadStats();
    }

    pub fn setStatus(self: *Host, name: []const u8, level: []const u8, max_players: u32, game_type: i32) void {
        const status = &self.shared.status;
        status.mutex.lockUncancelable(self.io());
        defer status.mutex.unlock(self.io());
        status.name.set(name);
        status.level.set(level);
        status.max_players = max_players;
        status.game_type = game_type;
    }

    pub fn isLive(self: *const Host, session: u64) bool {
        const parts = sessionParts(session) orelse return false;
        if (parts.index >= self.shared.live.len) return false;
        return self.shared.live[parts.index].load(.acquire) == parts.generation;
    }

    pub fn maxBatchPayload(self: *const Host) usize {
        return @min(self.config.max_batch_bytes, max_frame_bytes - 64, self.shared.commands.maxRecord() - 64);
    }

    /// Reserves one send record for `count` packets totalling `bytes`, to be filled with `writePacket`.
    pub fn beginSend(self: *Host, session: u64, count: usize, bytes: usize) SendError!Batch {
        if (count == 0) return error.EmptyBatch;
        if (count > max_packets_per_batch) return error.TooManyPackets;
        const total = 4 * count + bytes;
        if (total > self.maxBatchPayload()) return error.TooLarge;
        if (!self.running() or !self.isLive(session)) return error.Closed;
        const record = self.shared.commands.reserve(@backingInt(Command.send), 8 + total, 0) orelse return error.Backpressure;
        std.mem.writeInt(u64, record[0..8], session, .little);
        return .{ .bytes = record, .offset = 8 };
    }

    pub const Batch = struct {
        bytes: []u8,
        offset: usize,

        /// Space for a packet of `len` bytes, already length-prefixed.
        pub fn packet(self: *Batch, len: usize) []u8 {
            std.mem.writeInt(u32, self.bytes[self.offset..][0..4], @intCast(len), .little);
            const out = self.bytes[self.offset + 4 ..][0..len];
            self.offset += 4 + len;
            return out;
        }
    };

    pub fn commitSend(self: *Host, batch: Batch) void {
        std.debug.assert(batch.offset == batch.bytes.len);
        self.submit();
    }

    pub fn send(self: *Host, session: u64, packets: []const []const u8) SendError!void {
        var bytes: usize = 0;
        for (packets) |packet| {
            if (packet.len == 0) return error.EmptyBatch;
            bytes += packet.len;
        }
        var batch = try self.beginSend(session, packets.len, bytes);
        for (packets) |packet| @memcpy(batch.packet(packet.len), packet);
        self.commitSend(batch);
    }

    pub fn disconnect(self: *Host, session: u64) SendError!void {
        return self.sessionCommand(.disconnect, session, &.{});
    }

    /// For hosts that verified the login themselves, such as offline mode.
    pub fn acceptLogin(self: *Host, session: u64, client_key_der: []const u8) SendError!void {
        if (client_key_der.len == 0 or client_key_der.len > 512) return error.TooLarge;
        return self.sessionCommand(.accept_login, session, client_key_der);
    }

    pub fn nextEvent(self: *Host) ?Delivered {
        const record = self.shared.events.next() orelse return null;
        const bytes = record.bytes;
        const session = std.mem.readInt(u64, bytes[0..8], .little);
        return switch (@as(Event, @fromBackingInt(@intCast(record.tag)))) {
            .packet => .{ .packet = .{ .session = session, .bytes = bytes[8..] } },
            .disconnect => .{ .disconnect = .{ .session = session, .reason = @fromBackingInt(bytes[8]) } },
            .connect => blk: {
                const address_len = std.mem.readInt(u16, bytes[8..10], .little);
                const identity_len = bytes[10];
                const address = bytes[11..][0..address_len];
                const identity = bytes[11 + address_len ..][0..identity_len];
                break :blk .{ .connect = .{
                    .session = session,
                    .address = address,
                    .identity = if (identity_len == 0) null else identity,
                    .network_id = bytes[11 + address_len + identity_len ..],
                } };
            },
            .login => blk: {
                const name_len = std.mem.readInt(u16, bytes[8..10], .little);
                break :blk .{ .login = .{
                    .session = session,
                    .uuid = bytes[10..46],
                    .name = bytes[46..][0..name_len],
                    .xuid = bytes[46 + name_len ..],
                } };
            },
        };
    }

    pub fn releaseEvents(self: *Host) void {
        self.shared.events.release();
        if (self.shared.wants_events_space.swap(false, .seq_cst)) self.shared.wakeup.signal(self.io());
    }

    pub fn waitEvents(self: *Host, timeout_ms: u32) void {
        if (timeout_ms == 0 or !self.shared.events.isEmpty()) return;
        const seq = self.shared.event_seq.load(.seq_cst);
        self.shared.consumer_waiting.store(true, .seq_cst);
        defer self.shared.consumer_waiting.store(false, .seq_cst);
        if (!self.shared.events.isEmpty() or self.shared.exited.load(.seq_cst)) return;
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(timeout_ms), .clock = .awake } };
        self.io().futexWaitTimeout(u32, &self.shared.event_seq.raw, seq, timeout) catch {};
    }

    fn sessionCommand(self: *Host, kind: Command, session: u64, tail: []const u8) SendError!void {
        if (!self.running() or !self.isLive(session)) return error.Closed;
        const bytes = self.shared.commands.reserve(@backingInt(kind), 8 + tail.len, 0) orelse return error.Backpressure;
        std.mem.writeInt(u64, bytes[0..8], session, .little);
        @memcpy(bytes[8..], tail);
        self.submit();
    }

    fn submit(self: *Host) void {
        self.shared.commands.commit();
        self.shared.commands.publish();
        self.shared.wakeup.signal(self.io());
    }
};
