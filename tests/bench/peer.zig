const std = @import("std");
const bedwire = @import("bedwire");
const raknet = @import("raknet");
const packets = @import("packets");

const Ecdsa = bedwire.crypto.spki.Ecdsa;
pub const gameplay_id = 1020;

pub const Peer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    rak: *raknet.Client,
    session: bedwire.Session,
    received: usize = 0,
    latencies: ?*std.ArrayList(u64) = null,

    pub fn connect(allocator: std.mem.Allocator, io: std.Io, port: u16, pool: *bedwire.BufferPool) !*Peer {
        const self = try allocator.create(Peer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .rak = undefined,
            .session = try bedwire.Session.init(.client, .{ .pool = pool, .policy = .{ .encryption = .optional } }),
        };
        errdefer self.session.deinit();
        self.rak = try raknet.Client.connect(allocator, io, .{ .ip4 = .loopback(port) }, .{});
        return self;
    }

    pub fn destroy(self: *Peer) void {
        self.rak.destroy();
        self.session.deinit();
        self.allocator.destroy(self);
    }

    pub fn send(self: *Peer, batch: []const []const u8) !void {
        const frame = try self.session.encode(batch);
        defer frame.release();
        try self.rak.send(frame.bytes, .reliable_ordered, 0);
    }

    pub fn pump(self: *Peer, ms: u32) void {
        _ = self.rak.poll(.{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }, self, onMessage) catch {};
    }

    pub fn waitFor(self: *Peer, count: usize, timeout_ms: u32) !void {
        const end = nowNs(self.io) + @as(u64, timeout_ms) * std.time.ns_per_ms;
        while (self.received < count) {
            if (nowNs(self.io) > end) return error.Timeout;
            self.pump(1);
        }
    }

    pub fn login(self: *Peer) !void {
        var storage: [256]u8 = undefined;
        try self.send(&.{packets.request(&storage)});
        try self.waitFor(1, 5000);
        try self.send(&.{packets.login(&storage)});
        try self.session.advance(.resource_packs);
        try self.waitFor(2, 5000);
        try self.send(&.{packets.stackFinished(&storage)});
        try self.session.advance(.waiting_for_start_game);
        try self.waitFor(3, 5000);
        try self.session.advance(.spawn_ready);
        try self.send(&.{packets.raw(&storage, packets.id(.set_local_player_as_initialised), "\x01")});
        try self.session.advance(.in_game);
        self.received = 0;
    }

    fn onMessage(context: *anyopaque, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
        const self: *Peer = @ptrCast(@alignCast(context));
        var batch = self.session.ingest(payload.bytes) catch return error.ApplicationFailure;
        defer batch.deinit();
        while (batch.next()) |packet| {
            self.received += 1;
            if (packet.kind == .network_settings) self.session.negotiateFromSettings(packet) catch return error.ApplicationFailure;
            if (self.latencies) |list| if (packet.id == gameplay_id and packet.bytes.len >= 10) {
                const sent = std.mem.readInt(u64, packet.bytes[2..10], .little);
                list.append(self.allocator, nowNs(self.io) -| sent) catch {};
            };
        }
    }
};

pub fn clientPool(allocator: std.mem.Allocator) !bedwire.BufferPool {
    return bedwire.BufferPool.init(allocator, .{
        .max_frame_bytes = 1024 * 1024,
        .max_batch_bytes = 1024 * 1024,
        .max_packet_bytes = 1024 * 1024,
    }, .{ .rx_slots = 1, .tx_slots = 1 });
}

pub fn publicKeyDer() [120]u8 {
    const seed: [Ecdsa.SecretKey.encoded_length]u8 = @splat(7);
    const pair = Ecdsa.KeyPair.fromSecretKey(Ecdsa.SecretKey.fromBytes(seed) catch unreachable) catch unreachable;
    return bedwire.crypto.spki.encode(pair.public_key);
}

pub fn serverPackets(storage: *[3][256]u8) [3][]const u8 {
    return .{
        packets.networkSettings(&storage[0], .zlib, 256),
        packets.resourcePacksInfo(&storage[1]),
        packets.raw(&storage[2], packets.id(.start_game), "start"),
    };
}

pub fn stamped(storage: []u8, io: std.Io, size: usize) []const u8 {
    const len = bedwire.framing.varint.writeU32(storage, gameplay_id) catch unreachable;
    std.mem.writeInt(u64, storage[len..][0..8], nowNs(io), .little);
    @memset(storage[len + 8 .. size], 0x5a);
    return storage[0..size];
}

pub fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

pub fn percentile(sorted: []const u64, p: f64) u64 {
    if (sorted.len == 0) return 0;
    const index: usize = @intFromFloat(@as(f64, @floatFromInt(sorted.len - 1)) * p);
    return sorted[index];
}
