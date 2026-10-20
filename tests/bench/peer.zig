//! A NetherNet game client for benchmarks: it logs in like vanilla and timestamps its traffic.
const std = @import("std");
const bedwire = @import("bedwire");
const nethernet = @import("nethernet");

const protocol = bedwire.protocol;
const Ecdsa = bedwire.crypto.spki.Ecdsa;

/// Packets that carry an 8-byte send timestamp, so round trips can be measured on echo.
pub const stamp_id = protocol.Current.packetId(.text).?;

pub fn nowNs(io: std.Io) u64 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

pub fn clientPool(allocator: std.mem.Allocator) !bedwire.BufferPool {
    return bedwire.BufferPool.init(allocator, .{
        .max_frame_bytes = 4 * 1024 * 1024,
        .max_batch_bytes = 1024 * 1024,
        .max_packet_bytes = 1024 * 1024,
    }, .{ .rx_slots = 1, .tx_slots = 1 });
}

pub fn stamped(storage: []u8, io: std.Io, size: usize) []const u8 {
    storage[0] = stamp_id;
    std.mem.writeInt(u64, storage[1..9], nowNs(io), .little);
    @memset(storage[9..size], 'p');
    return storage[0..size];
}

pub const Peer = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    connection: *nethernet.Connection,
    session: bedwire.Session,
    key: Ecdsa.KeyPair,
    received: usize = 0,
    closed: bool = false,
    latencies: ?*std.ArrayList(u64) = null,

    pub fn connect(allocator: std.mem.Allocator, io: std.Io, port: u16, pool: *bedwire.BufferPool, wakeup: ?*nethernet.Wakeup) !*Peer {
        const self = try allocator.create(Peer);
        errdefer allocator.destroy(self);
        var origin: [64]u8 = undefined;
        var random: [8]u8 = undefined;
        io.random(&random);
        const connection = try nethernet.dialEndpoint(allocator, io, try std.fmt.bufPrint(&origin, "http://127.0.0.1:{d}", .{port}), std.mem.readInt(u64, &random, .little) | 1, .{
            .allow_anonymous = true,
            .maximum_message_size = 4 * 1024 * 1024,
        });
        errdefer connection.destroy();
        self.* = .{
            .allocator = allocator,
            .io = io,
            .connection = connection,
            .session = try bedwire.Session.init(.client, .{ .pool = pool, .policy = .{ .encryption = .disabled, .batch_header = false } }),
            .key = Ecdsa.KeyPair.generate(io),
        };
        if (wakeup) |shared| connection.peer.subscribe(shared);
        return self;
    }

    pub fn destroy(self: *Peer) void {
        self.session.deinit();
        self.connection.destroy();
        self.allocator.destroy(self);
    }

    pub fn send(self: *Peer, batch: []const []const u8) !void {
        const frame = try self.session.encode(batch);
        defer frame.release();
        try self.connection.send(frame.bytes, .reliable);
    }

    /// Handles everything already queued without blocking.
    pub fn pump(self: *Peer) void {
        while (!self.closed) {
            const event = self.connection.poll() catch {
                self.closed = true;
                return;
            } orelse return;
            if (event == .message) self.deliver(event.message.data) catch {
                self.closed = true;
            };
        }
    }

    fn deliver(self: *Peer, payload: []const u8) !void {
        var batch = try self.session.ingest(payload);
        defer batch.deinit();
        while (batch.next()) |packet| {
            self.received += 1;
            if (packet.kind == .network_settings) try self.session.negotiateFromSettings(packet);
            if (packet.id == stamp_id and packet.bytes.len >= 9) {
                if (self.latencies) |list| {
                    const sent = std.mem.readInt(u64, packet.bytes[1..9], .little);
                    try list.append(self.allocator, nowNs(self.io) -| sent);
                }
            }
        }
    }

    pub fn waitFor(self: *Peer, count: usize, timeout_ms: u32) !void {
        const end = nowNs(self.io) + @as(u64, timeout_ms) * std.time.ns_per_ms;
        while (self.received < count) {
            if (self.closed) return error.ConnectionClosed;
            if (nowNs(self.io) > end) return error.Timeout;
            const token = self.connection.prepareWait();
            self.pump();
            if (self.received >= count) break;
            self.connection.peer.wakeup.wait(self.io, token, .{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }) catch {};
        }
    }

    /// The client half of `serverLogin`: settings, login, packs and spawn.
    pub fn login(self: *Peer) !void {
        var storage: [512]u8 = undefined;
        try self.send(&.{typed(&storage, .{ .request_network_settings = .{ .client_network_version = protocol.Current.protocol_number } })});
        try self.waitFor(1, 10_000);
        try self.send(&.{typed(&storage, .{ .login = .{ .client_network_version = protocol.Current.protocol_number, .connection_request = "bench" } })});
        try self.waitFor(3, 10_000);
        try self.send(&.{typed(&storage, .{ .resource_pack_client_response = .{ .response = .{ .resource_pack_stack_finished = "resourcepackstackfinished" } } })});
        try self.session.advance(.waiting_for_start_game);
        try self.waitFor(4, 10_000);
        try self.session.advance(.spawn_ready);
        try self.send(&.{raw(&storage, protocol.Current.packetId(.set_local_player_as_initialised).?, "\x01")});
        try self.session.advance(.in_game);
        self.received = 0;
    }
};

pub fn typed(storage: []u8, packet: protocol.typed.Packet) []const u8 {
    var writer = protocol.Writer.init(storage);
    protocol.typed.encode(&writer, .{ .header = .{ .packet_id = protocol.Current.packetId(protocol.typed.packetKind(packet)).? }, .packet = packet }) catch unreachable;
    return writer.written();
}

pub fn raw(storage: []u8, packet_id: u10, body: []const u8) []const u8 {
    const len = bedwire.framing.varint.writeU32(storage, packet_id) catch unreachable;
    @memmove(storage[len..][0..body.len], body);
    return storage[0 .. len + body.len];
}
