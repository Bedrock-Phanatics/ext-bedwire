const std = @import("std");
const bedwire = @import("bedwire");
const nethernet = @import("nethernet");
const native = @import("native");
const packets = @import("packets.zig");

const testing = std.testing;
pub const Ecdsa = bedwire.crypto.spki.Ecdsa;

pub const loopback = std.Io.net.IpAddress{ .ip4 = .loopback(0) };

pub fn config(overrides: anytype) native.Config {
    var result: native.Config = .{
        .address = loopback,
        .authentication = false,
        .max_sessions = 16,
        .max_batch_bytes = 64 * 1024,
        .event_queue_bytes = 1024 * 1024,
        .command_queue_bytes = 1024 * 1024,
        .stats_interval_ms = 50,
        .max_negotiations = 8,
        .http_workers = 8,
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
    login: u64,
    unreliable: struct { session: u64, bytes: []u8 },

    pub fn deinit(self: Owned) void {
        switch (self) {
            .packet => |packet| testing.allocator.free(packet.bytes),
            .unreliable => |unreliable| testing.allocator.free(unreliable.bytes),
            else => {},
        }
    }
};

pub fn nextEvent(host: *native.Host, timeout_ms: u32) !Owned {
    const deadline = Deadline.in(host.io(), timeout_ms);
    while (!deadline.expired()) {
        if (host.nextEvent()) |event| {
            const owned: Owned = switch (event) {
                .connect => |c| .{ .connect = c.session },
                .disconnect => |d| .{ .disconnect = .{ .session = d.session, .reason = d.reason } },
                .packet => |p| .{ .packet = .{ .session = p.session, .bytes = try testing.allocator.dupe(u8, p.bytes) } },
                .login => |l| .{ .login = l.session },
                .unreliable => |u| .{ .unreliable = .{ .session = u.session, .bytes = try testing.allocator.dupe(u8, u.bytes) } },
            };
            host.releaseEvents();
            return owned;
        }
        host.releaseEvents();
        host.waitEvents(5);
    }
    return error.Timeout;
}

pub fn expectConnect(host: *native.Host) !u64 {
    const event = try nextEvent(host, 10_000);
    defer event.deinit();
    if (event != .connect) return error.UnexpectedEvent;
    return event.connect;
}

pub fn expectDisconnect(host: *native.Host, session: u64, reason: native.Reason) !void {
    while (true) {
        const event = try nextEvent(host, 10_000);
        defer event.deinit();
        switch (event) {
            .packet => continue,
            .disconnect => |d| {
                try testing.expectEqual(session, d.session);
                try testing.expectEqual(reason, d.reason);
                return;
            },
            else => return error.UnexpectedEvent,
        }
    }
}

/// A vanilla-shaped NetherNet client: HTTP signaling, no batch header and no Bedrock encryption.
pub const Client = struct {
    io: std.Io,
    connection: *nethernet.Connection,
    wakeup: nethernet.Wakeup = .{},
    pool: bedwire.BufferPool,
    session: bedwire.Session,
    key: Ecdsa.KeyPair,
    received: std.ArrayList([]u8) = .empty,
    unreliable: std.ArrayList([]u8) = .empty,
    closed: bool = false,

    pub fn connect(io: std.Io, port: u16) !*Client {
        return connectWith(io, port, options);
    }

    pub fn connectWith(io: std.Io, port: u16, connection_options: nethernet.ConnectionOptions) !*Client {
        var origin: [64]u8 = undefined;
        var random: [8]u8 = undefined;
        io.random(&random);
        const connection = try nethernet.dialEndpoint(
            testing.allocator,
            io,
            try std.fmt.bufPrint(&origin, "http://127.0.0.1:{d}", .{port}),
            std.mem.readInt(u64, &random, .little) | 1,
            connection_options,
        );
        return adopt(io, connection);
    }

    pub const options: nethernet.ConnectionOptions = .{ .allow_anonymous = true, .maximum_message_size = 4 * 1024 * 1024 };

    /// Takes ownership of an established connection, also on failure.
    pub fn adopt(io: std.Io, connection: *nethernet.Connection) !*Client {
        errdefer connection.destroy();
        const self = try testing.allocator.create(Client);
        errdefer testing.allocator.destroy(self);
        var pool = try bedwire.BufferPool.init(testing.allocator, .{
            .max_frame_bytes = 4 * 1024 * 1024,
            .max_batch_bytes = 1024 * 1024,
            .max_packet_bytes = 1024 * 1024,
        }, .{ .rx_slots = 1, .tx_slots = 1 });
        errdefer pool.deinit();
        self.* = .{
            .io = io,
            .connection = connection,
            .pool = pool,
            .session = undefined,
            .key = Ecdsa.KeyPair.generate(io),
        };
        self.session = try bedwire.Session.init(.client, .{ .pool = &self.pool, .policy = .{ .encryption = .disabled, .batch_header = false } });
        connection.peer.subscribe(&self.wakeup);
        return self;
    }

    pub fn destroy(self: *Client) void {
        for (self.received.items) |packet| testing.allocator.free(packet);
        self.received.deinit(testing.allocator);
        for (self.unreliable.items) |message| testing.allocator.free(message);
        self.unreliable.deinit(testing.allocator);
        self.session.deinit();
        self.connection.destroy();
        self.pool.deinit();
        testing.allocator.destroy(self);
    }

    pub fn send(self: *Client, batch: []const []const u8) !void {
        const frame = try self.session.encode(batch);
        defer frame.release();
        try self.connection.send(frame.bytes, .reliable);
    }

    pub fn sendRaw(self: *Client, payload: []const u8) !void {
        try self.connection.send(payload, .reliable);
    }

    pub fn pump(self: *Client, ms: u32) void {
        const token = self.wakeup.prepare();
        while (!self.closed) {
            const event = self.connection.poll() catch {
                self.closed = true;
                return;
            } orelse break;
            if (event != .message) continue;
            if (event.message.reliability == .unreliable) {
                const copy = testing.allocator.dupe(u8, event.message.data) catch return;
                self.unreliable.append(testing.allocator, copy) catch testing.allocator.free(copy);
                continue;
            }
            self.deliver(event.message.data) catch {
                self.closed = true;
                return;
            };
        }
        self.wakeup.wait(self.io, token, .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } }) catch {};
    }

    fn deliver(self: *Client, payload: []const u8) !void {
        var batch = try self.session.ingest(payload);
        defer batch.deinit();
        while (batch.next()) |packet| {
            if (packet.kind == .network_settings) try self.session.negotiateFromSettings(packet);
            const copy = try testing.allocator.dupe(u8, packet.bytes);
            errdefer testing.allocator.free(copy);
            try self.received.append(testing.allocator, copy);
        }
    }

    pub fn expectPackets(self: *Client, count: usize, timeout_ms: u32) ![][]u8 {
        const deadline = Deadline.in(self.io, timeout_ms);
        while (self.received.items.len < count) {
            if (deadline.expired()) return error.Timeout;
            self.pump(5);
        }
        return self.received.items[0..count];
    }

    pub fn expectClosed(self: *Client, timeout_ms: u32) !void {
        const deadline = Deadline.in(self.io, timeout_ms);
        while (!self.closed) {
            if (deadline.expired()) return error.Timeout;
            self.pump(5);
        }
    }

    pub fn clear(self: *Client) void {
        for (self.received.items) |packet| testing.allocator.free(packet);
        self.received.clearRetainingCapacity();
    }
};

pub fn expectPacket(host: *native.Host, session: u64, expected: []const u8) !void {
    const event = try nextEvent(host, 5000);
    defer event.deinit();
    if (event != .packet) return error.UnexpectedEvent;
    try testing.expectEqual(session, event.packet.session);
    try testing.expectEqualSlices(u8, expected, event.packet.bytes);
}

/// Connects and walks the vanilla NetherNet login with the host verifying the client key itself.
pub fn join(host: *native.Host, compression: packets.Compression) !struct { client: *Client, session: u64 } {
    const client = try Client.connect(host.io(), host.local_address.getPort());
    errdefer client.destroy();
    const session = try expectConnect(host);
    try login(host, client, session, compression);
    return .{ .client = client, .session = session };
}

pub fn login(host: *native.Host, client: *Client, session: u64, compression: packets.Compression) !void {
    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;

    const request = packets.request(&a);
    try client.send(&.{request});
    try expectPacket(host, session, request);

    try host.send(session, &.{packets.networkSettings(&b, compression, 1)});
    _ = try client.expectPackets(1, 5000);
    try testing.expectEqual(bedwire.State.authenticating, client.session.state);

    const login_packet = packets.login(&a);
    try client.send(&.{login_packet});
    try expectPacket(host, session, login_packet);
    try host.acceptLogin(session, &bedwire.crypto.spki.encode(client.key.public_key));

    var status: [16]u8 = undefined;
    try host.send(session, &.{ packets.playStatus(&status), packets.resourcePacksInfo(&b) });
    _ = try client.expectPackets(3, 5000);
    try testing.expectEqual(bedwire.State.resource_packs, client.session.state);

    const finished = packets.stackFinished(&a);
    try client.send(&.{finished});
    try expectPacket(host, session, finished);
    try client.session.advance(.waiting_for_start_game);

    var start: [16]u8 = undefined;
    var after: [16]u8 = undefined;
    try host.send(session, &.{ packets.raw(&start, packets.id(.start_game), "start"), packets.raw(&after, 1020, "after-start") });
    _ = try client.expectPackets(5, 5000);
    try client.session.advance(.spawn_ready);

    const initialised = packets.raw(&a, packets.id(.set_local_player_as_initialised), "\x01");
    try client.send(&.{initialised});
    try expectPacket(host, session, initialised);
    try client.session.advance(.in_game);
    client.clear();
}
