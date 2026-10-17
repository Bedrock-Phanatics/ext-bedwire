const std = @import("std");
const bedwire = @import("bedwire");
const raknet = @import("raknet");
const native = @import("native");
const packets = @import("packets.zig");

const testing = std.testing;
pub const Ecdsa = bedwire.crypto.spki.Ecdsa;

pub const loopback = std.Io.net.IpAddress{ .ip4 = .loopback(0) };
pub const advertisement = "MCPE;ext-bedwire;2193;1.0;0;10;1;test;Survival;1;19132;19133;";

pub fn config(overrides: anytype) native.Config {
    var result: native.Config = .{
        .address = loopback,
        .advertisement = advertisement,
        .max_sessions = 16,
        .max_batch_bytes = 64 * 1024,
        .event_queue_bytes = 1024 * 1024,
        .command_queue_bytes = 1024 * 1024,
        .max_receipts = 64,
        .ping_interval_ms = 200,
    };
    inline for (comptime std.meta.fieldNames(@TypeOf(overrides))) |name| @field(result, name) = @field(overrides, name);
    return result;
}

pub const Deadline = struct {
    io: std.Io,
    end: i96,

    pub fn in(io: std.Io, ms: u32) Deadline {
        return .{ .io = io, .end = std.Io.Clock.awake.now(io).nanoseconds + @as(i96, ms) * std.time.ns_per_ms };
    }

    pub fn expired(self: Deadline) bool {
        return std.Io.Clock.awake.now(self.io).nanoseconds >= self.end;
    }
};

pub const Owned = union(native.Event) {
    connect: u64,
    disconnect: struct { session: u64, reason: native.Reason },
    packet: struct { session: u64, bytes: []u8 },
    receipt_ack: u64,
    receipt_failed: u64,
    ping: u64,
    raw: struct { port: u16, bytes: []u8 },

    pub fn deinit(self: Owned) void {
        switch (self) {
            .packet => |p| testing.allocator.free(p.bytes),
            .raw => |r| testing.allocator.free(r.bytes),
            else => {},
        }
    }
};

pub fn nextEvent(host: *native.Host, timeout_ms: u32, pump: anytype) !Owned {
    const deadline = Deadline.in(host.io(), timeout_ms);
    while (!deadline.expired()) {
        if (host.nextEvent()) |event| {
            const owned: Owned = switch (event) {
                .connect => |c| .{ .connect = c.session },
                .disconnect => |d| .{ .disconnect = .{ .session = d.session, .reason = d.reason } },
                .packet => |p| .{ .packet = .{ .session = p.session, .bytes = try testing.allocator.dupe(u8, p.bytes) } },
                .receipt_ack => |r| .{ .receipt_ack = r.value },
                .receipt_failed => |r| .{ .receipt_failed = r.value },
                .ping => continue,
                .raw => |r| .{ .raw = .{ .port = r.port, .bytes = try testing.allocator.dupe(u8, r.bytes) } },
            };
            host.releaseEvents();
            return owned;
        }
        host.releaseEvents();
        if (@TypeOf(pump) != @TypeOf(null)) pump.pump(5) else host.waitEvents(5);
    }
    return error.Timeout;
}

pub const Client = struct {
    io: std.Io,
    rak: *raknet.Client,
    pool: bedwire.BufferPool,
    session: bedwire.Session,
    key: Ecdsa.KeyPair,
    received: std.ArrayList([]u8) = .empty,
    handshake_failed: bool = false,

    pub fn connect(io: std.Io, port: u16, options: raknet.ClientOptions) !*Client {
        const self = try testing.allocator.create(Client);
        errdefer testing.allocator.destroy(self);
        self.io = io;
        self.rak = try raknet.Client.connect(testing.allocator, io, .{ .ip4 = .loopback(port) }, options);
        errdefer self.rak.destroy();
        self.pool = try bedwire.BufferPool.init(testing.allocator, .{
            .max_frame_bytes = 4 * 1024 * 1024,
            .max_batch_bytes = 1024 * 1024,
            .max_packet_bytes = 1024 * 1024,
        }, .{ .rx_slots = 1, .tx_slots = 1 });
        errdefer self.pool.deinit();
        self.session = try bedwire.Session.init(.client, .{ .pool = &self.pool });
        self.key = Ecdsa.KeyPair.generate(io);
        self.received = .empty;
        self.handshake_failed = false;
        return self;
    }

    pub fn destroy(self: *Client) void {
        for (self.received.items) |packet| testing.allocator.free(packet);
        self.received.deinit(testing.allocator);
        self.session.deinit();
        self.pool.deinit();
        self.rak.destroy();
        testing.allocator.destroy(self);
    }

    pub fn send(self: *Client, batch: []const []const u8) !void {
        const frame = try self.session.encode(batch);
        defer frame.release();
        try self.rak.send(frame.bytes, .reliable_ordered, 0);
    }

    pub fn sendRaw(self: *Client, payload: []const u8) !void {
        try self.rak.send(payload, .reliable_ordered, 0);
    }

    pub fn pump(self: *Client, ms: u32) void {
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
        if (self.rak.isClosed()) return self.io.sleep(.fromMilliseconds(ms), .awake) catch {};
        _ = self.rak.poll(timeout, self, onMessage) catch {};
    }

    pub fn expectPackets(self: *Client, count: usize, timeout_ms: u32) ![][]u8 {
        const deadline = Deadline.in(self.io, timeout_ms);
        while (self.received.items.len < count) {
            if (deadline.expired()) return error.Timeout;
            self.pump(5);
        }
        return self.received.items[0..count];
    }

    pub fn clear(self: *Client) void {
        for (self.received.items) |packet| testing.allocator.free(packet);
        self.received.clearRetainingCapacity();
    }

    fn onMessage(context: *anyopaque, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
        const self: *Client = @ptrCast(@alignCast(context));
        var batch = self.session.ingest(payload.bytes) catch return error.ApplicationFailure;
        defer batch.deinit();
        while (batch.next()) |packet| {
            if (packet.kind == .server_to_client_handshake) {
                self.session.acceptServerHandshakePacket(testing.allocator, packet, self.key.secret_key) catch {
                    self.handshake_failed = true;
                };
            } else if (packet.kind == .network_settings) {
                self.session.negotiateFromSettings(packet) catch return error.ApplicationFailure;
            }
            const copy = testing.allocator.dupe(u8, packet.bytes) catch return error.ApplicationFailure;
            self.received.append(testing.allocator, copy) catch {
                testing.allocator.free(copy);
                return error.ApplicationFailure;
            };
        }
    }
};

pub fn expectPacket(host: *native.Host, client: *Client, session: u64, expected: []const u8) !void {
    const event = try nextEvent(host, 5000, client);
    defer event.deinit();
    if (event != .packet) return error.UnexpectedEvent;
    try testing.expectEqual(session, event.packet.session);
    try testing.expectEqualSlices(u8, expected, event.packet.bytes);
}

pub fn login(host: *native.Host, client: *Client, session: u64, compression: packets.Compression) !void {
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;

    const request = packets.request(&a);
    try client.send(&.{request});
    try expectPacket(host, client, session, request);

    _ = try host.send(session, &.{packets.networkSettings(&b, compression, 1)}, false);
    _ = try client.expectPackets(1, 5000);
    try testing.expectEqual(bedwire.State.authenticating, client.session.state);

    const login_packet = packets.login(&a);
    try client.send(&.{login_packet});
    try expectPacket(host, client, session, login_packet);

    const server_key = Ecdsa.KeyPair.generate(host.io());
    var salt: [16]u8 = undefined;
    host.io().random(&salt);
    const token = try bedwire.auth.login.serverHandshake(testing.allocator, server_key, salt, .{});
    defer testing.allocator.free(token);
    const key = try bedwire.crypto.ecdh.derive(server_key.secret_key, client.key.public_key, salt);
    try host.enableEncryption(session, packets.typed(&b, .{ .server_to_client_handshake = .{ .handshake_web_token = token } }), &key);
    _ = try client.expectPackets(2, 5000);
    try testing.expect(!client.handshake_failed);
    try testing.expect(client.session.encrypted());

    const c2s = packets.typed(&a, .{ .client_to_server_handshake = .{} });
    try client.send(&.{c2s});
    try expectPacket(host, client, session, c2s);
    try client.session.advance(.resource_packs);

    var status: [16]u8 = undefined;
    _ = try host.send(session, &.{ packets.raw(&status, packets.id(.play_status), "\x00\x00\x00\x00"), packets.resourcePacksInfo(&b) }, false);
    _ = try client.expectPackets(4, 5000);

    const finished = packets.stackFinished(&a);
    try client.send(&.{finished});
    try expectPacket(host, client, session, finished);
    try client.session.advance(.waiting_for_start_game);

    var start: [16]u8 = undefined;
    var after: [16]u8 = undefined;
    _ = try host.send(session, &.{ packets.raw(&start, packets.id(.start_game), "start"), packets.raw(&after, 1020, "after-start") }, false);
    _ = try client.expectPackets(6, 5000);
    try client.session.advance(.spawn_ready);

    const initialised = packets.raw(&a, packets.id(.set_local_player_as_initialised), "\x01");
    try client.send(&.{initialised});
    try expectPacket(host, client, session, initialised);
    try client.session.advance(.in_game);
    client.clear();
}
