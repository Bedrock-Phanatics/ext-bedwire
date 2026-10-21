const std = @import("std");
const bedwire = @import("bedwire");
const nethernet = @import("nethernet");
const native = @import("native");
const packets = @import("packets.zig");
const support = @import("support.zig");

const testing = std.testing;
const gpa = testing.allocator;

fn start(overrides: anytype) !*native.Host {
    return native.Host.start(gpa, support.config(overrides));
}

test "a vanilla-shaped client logs in and exchanges batched gameplay" {
    const host = try start(.{});
    defer host.destroy();
    const joined = try support.join(host, .zlib);
    const client = joined.client;
    defer client.destroy();

    var a: [64]u8 = undefined;
    var b: [64]u8 = undefined;
    var c: [8192]u8 = undefined;
    @memset(&c, 'x');
    const first = packets.raw(&a, packets.id(.text), "hello");
    const second = packets.raw(&b, packets.id(.text), "world");
    const large = packets.raw(&c, packets.id(.text), c[0..4000]);
    try host.send(joined.session, &.{ first, second, large });
    const received = try client.expectPackets(3, 5000);
    try testing.expectEqualSlices(u8, first, received[0]);
    try testing.expectEqualSlices(u8, second, received[1]);
    try testing.expectEqualSlices(u8, large, received[2]);

    try client.send(&.{ first, second });
    try support.expectPacket(host, joined.session, first);
    try support.expectPacket(host, joined.session, second);

    try testing.expect(host.statistics().packets_received >= 6);
}

test "snappy and uncompressed sessions work through the worker" {
    const host = try start(.{});
    defer host.destroy();
    for ([_]packets.Compression{ .snappy, .none }) |algorithm| {
        const joined = try support.join(host, algorithm);
        var a: [64]u8 = undefined;
        const text = packets.raw(&a, packets.id(.text), "compressed");
        try host.send(joined.session, &.{text});
        try testing.expectEqualSlices(u8, text, (try joined.client.expectPackets(1, 5000))[0]);
        joined.client.destroy();
        try support.expectDisconnect(host, joined.session, .remote);
    }
}

test "large frames are fragmented and reassembled in order" {
    const host = try start(.{ .max_batch_bytes = 2 * 1024 * 1024, .event_queue_bytes = 16 * 1024 * 1024, .command_queue_bytes = 8 * 1024 * 1024 });
    defer host.destroy();
    const joined = try support.join(host, .none);
    defer joined.client.destroy();

    const body = try gpa.alloc(u8, 900 * 1024);
    defer gpa.free(body);
    for (body, 0..) |*byte, i| byte.* = @truncate(i *% 31);
    const storage = try gpa.alloc(u8, body.len + 8);
    defer gpa.free(storage);
    const big = packets.raw(storage, packets.id(.text), body);
    try host.send(joined.session, &.{big});
    try testing.expectEqualSlices(u8, big, (try joined.client.expectPackets(1, 10_000))[0]);
    try joined.client.send(&.{big});
    try support.expectPacket(host, joined.session, big);
}

test "stale session IDs never reach a reused slot" {
    const host = try start(.{ .max_sessions = 1 });
    defer host.destroy();
    const first = try support.join(host, .none);
    try host.disconnect(first.session);
    try support.expectDisconnect(host, first.session, .server);
    first.client.destroy();

    const second = try support.join(host, .none);
    defer second.client.destroy();
    try testing.expect(first.session != second.session);
    var a: [16]u8 = undefined;
    try testing.expectError(error.Closed, host.send(first.session, &.{packets.raw(&a, packets.id(.text), "x")}));
    try testing.expectError(error.Closed, host.disconnect(first.session));
}

test "a server disconnect delivers queued packets before the connection closes" {
    const host = try start(.{});
    defer host.destroy();
    const joined = try support.join(host, .none);
    defer joined.client.destroy();
    var a: [64]u8 = undefined;
    const goodbye = packets.typed(&a, .{ .disconnect = .{ .reason = @fromBackingInt(0), .messages = .{ .messages = .{ .message = "bye", .filtered_message = "" } } } });
    try host.send(joined.session, &.{goodbye});
    try host.disconnect(joined.session);
    try testing.expectEqualSlices(u8, goodbye, (try joined.client.expectPackets(1, 5000))[0]);
    try support.expectDisconnect(host, joined.session, .server);
    try joined.client.expectClosed(5000);
}

test "malformed batches close the session with a protocol reason" {
    const host = try start(.{});
    defer host.destroy();
    const joined = try support.join(host, .zlib);
    defer joined.client.destroy();
    try joined.client.sendRaw("\x00\xff\xff\xff\xff\xff");
    try support.expectDisconnect(host, joined.session, .protocol);
    try testing.expectEqual(@as(u64, 1), host.statistics().protocol_disconnects);
}

test "out-of-stage packets from the client are refused" {
    const host = try start(.{});
    defer host.destroy();
    const client = try support.Client.connect(host.io(), host.local_address.getPort());
    defer client.destroy();
    const session = try support.expectConnect(host);
    var a: [64]u8 = undefined;
    try client.sendRaw(packets.raw(&a, packets.id(.text), "too early"));
    try support.expectDisconnect(host, session, .protocol);
}

test "packets the server stage forbids are dropped, not sent" {
    const host = try start(.{});
    defer host.destroy();
    const client = try support.Client.connect(host.io(), host.local_address.getPort());
    defer client.destroy();
    const session = try support.expectConnect(host);
    var a: [64]u8 = undefined;
    try host.send(session, &.{packets.raw(&a, packets.id(.start_game), "nope")});
    const deadline = support.Deadline.in(host.io(), 2000);
    while (host.statistics().packets_rejected == 0 and !deadline.expired()) client.pump(5);
    try testing.expectEqual(@as(u64, 1), host.statistics().packets_rejected);
    try testing.expectEqual(@as(usize, 0), client.received.items.len);
}

test "per-session packet rate limit disconnects floods" {
    const host = try start(.{ .packet_rate = 50 });
    defer host.destroy();
    const joined = try support.join(host, .none);
    defer joined.client.destroy();
    var a: [64]u8 = undefined;
    const text = packets.raw(&a, packets.id(.text), "spam");
    var batch: [200][]const u8 = undefined;
    @memset(&batch, text);
    try joined.client.send(&batch);
    try support.expectDisconnect(host, joined.session, .overload);
}

test "a stalled event consumer throttles peers instead of dropping packets" {
    const host = try start(.{ .event_queue_bytes = 512 * 1024, .max_batch_bytes = 64 * 1024 });
    defer host.destroy();
    const joined = try support.join(host, .none);
    defer joined.client.destroy();

    var body: [1024]u8 = undefined;
    const sent = 2000;
    for (0..sent) |i| {
        std.mem.writeInt(u32, body[0..4], @intCast(i), .little);
        var storage: [1100]u8 = undefined;
        try joined.client.send(&.{packets.raw(&storage, packets.id(.text), &body)});
    }
    // Give the worker time to fill the queue while nothing drains it.
    try host.io().sleep(.fromMilliseconds(300), .awake);
    try testing.expect(host.statistics().event_stalls > 0);

    var seen: usize = 0;
    while (seen < sent) {
        const event = try support.nextEvent(host, 10_000);
        defer event.deinit();
        if (event != .packet) return error.UnexpectedEvent;
        try testing.expectEqual(@as(u32, @intCast(seen)), std.mem.readInt(u32, event.packet.bytes[1..5], .little));
        seen += 1;
    }
    try testing.expectEqual(@as(u64, 0), host.statistics().overload_disconnects);
}

test "invalid send arguments are rejected before queueing" {
    const host = try start(.{});
    defer host.destroy();
    const joined = try support.join(host, .none);
    defer joined.client.destroy();
    try testing.expectError(error.EmptyBatch, host.send(joined.session, &.{}));
    try testing.expectError(error.EmptyBatch, host.send(joined.session, &.{""}));
    var many: [native.max_packets_per_batch + 1][]const u8 = undefined;
    @memset(&many, "\x09");
    try testing.expectError(error.TooManyPackets, host.send(joined.session, &many));
    const huge = try gpa.alloc(u8, host.maxBatchPayload() + 1);
    defer gpa.free(huge);
    try testing.expectError(error.TooLarge, host.send(joined.session, &.{huge}));
    try testing.expectError(error.Closed, host.send(0, &.{"\x09"}));
}

test "accepting a login in the wrong stage closes the session" {
    const host = try start(.{});
    defer host.destroy();
    const client = try support.Client.connect(host.io(), host.local_address.getPort());
    defer client.destroy();
    const session = try support.expectConnect(host);
    try host.acceptLogin(session, &bedwire.crypto.spki.encode(client.key.public_key));
    try support.expectDisconnect(host, session, .protocol);
}

test "a malformed client key fails authentication" {
    const host = try start(.{});
    defer host.destroy();
    const client = try support.Client.connect(host.io(), host.local_address.getPort());
    defer client.destroy();
    const session = try support.expectConnect(host);
    try host.acceptLogin(session, "not a key");
    try support.expectDisconnect(host, session, .authentication);
}

test "sessions that never log in time out" {
    const host = try start(.{ .login_timeout_ms = 200 });
    defer host.destroy();
    const client = try support.Client.connect(host.io(), host.local_address.getPort());
    defer client.destroy();
    const session = try support.expectConnect(host);
    try support.expectDisconnect(host, session, .timeout);
    try testing.expectEqual(@as(u64, 1), host.statistics().timeouts);
}

test "unreliable messages are dropped without closing the session" {
    const host = try start(.{});
    defer host.destroy();
    const joined = try support.join(host, .none);
    defer joined.client.destroy();
    try joined.client.connection.send("\x01\x02", .unreliable);
    var a: [64]u8 = undefined;
    const text = packets.raw(&a, packets.id(.text), "after");
    try joined.client.send(&.{text});
    try support.expectPacket(host, joined.session, text);
    try testing.expectEqual(@as(u64, 1), host.statistics().unreliable_dropped);
}

test "stop closes live sessions with a shutdown reason and is idempotent" {
    const host = try start(.{});
    defer host.destroy();
    const joined = try support.join(host, .none);
    defer joined.client.destroy();
    host.stop(1000);
    try testing.expect(!host.running());
    const event = try support.nextEvent(host, 1000);
    defer event.deinit();
    try testing.expectEqual(native.Reason.shutdown, event.disconnect.reason);
    host.stop(1000);
    try testing.expectError(error.Closed, host.send(joined.session, &.{"\x09"}));
}

test "authenticated servers refuse anonymous clients at signaling" {
    const host = try start(.{ .authentication = true });
    defer host.destroy();
    try testing.expect(std.meta.isError(support.Client.connect(host.io(), host.local_address.getPort())));
    try testing.expectEqual(@as(?native.Delivered, null), host.nextEvent());
}

test "the signaling endpoint reports the status PHP sets" {
    const host = try start(.{});
    defer host.destroy();
    host.setStatus("Quark \"test\"", "world", 20, 1);

    const io = host.io();
    const stream = try (std.Io.net.IpAddress{ .ip4 = .loopback(host.local_address.getPort()) }).connect(io, .{ .mode = .stream });
    defer stream.close(io);
    var write_buffer: [256]u8 = undefined;
    var writer = stream.writer(io, &write_buffer);
    try writer.interface.writeAll("GET /v1/join HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n");
    try writer.interface.flush();
    var read_buffer: [4096]u8 = undefined;
    var reader = stream.reader(io, &read_buffer);
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    _ = reader.interface.streamRemaining(&body.writer) catch {};
    const response = body.written();
    try testing.expect(std.mem.indexOf(u8, response, "\"name\":\"Quark \\\"test\\\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, response, "\"maxPlayers\":20") != null);
    try testing.expect(std.mem.indexOf(u8, response, std.fmt.comptimePrint("\"protocol\":{d}", .{bedwire.protocol.protocol_version})) != null);
}

test "invalid configurations are refused" {
    try testing.expectError(error.InvalidConfig, start(.{ .max_sessions = 0 }));
    try testing.expectError(error.InvalidConfig, start(.{ .max_batch_bytes = 1024 }));
    try testing.expectError(error.InvalidConfig, start(.{ .port_range_begin = 5000 }));
    try testing.expectError(error.InvalidConfig, start(.{ .receive_queue_bytes = 1 }));
}

test "a port already in use fails cleanly" {
    // Zig 0.17 binds Windows sockets through AFD without an exclusive share mode, so only Linux refuses here.
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const host = try start(.{});
    defer host.destroy();
    try testing.expect(std.meta.isError(start(.{ .address = std.Io.net.IpAddress{ .ip4 = .loopback(host.local_address.getPort()) } })));
}

test "queued single sends to one session coalesce without reordering" {
    const host = try start(.{});
    defer host.destroy();
    const joined = try support.join(host, .none);
    defer joined.client.destroy();
    var storage: [100][16]u8 = undefined;
    for (&storage, 0..) |*buffer, i| try host.send(joined.session, &.{packets.raw(buffer, packets.id(.text), &.{@intCast(i)})});
    const received = try joined.client.expectPackets(100, 5000);
    for (received, 0..) |packet, i| try testing.expectEqual(@as(u8, @intCast(i)), packet[packet.len - 1]);
    try testing.expect(host.statistics().batches_sent < 100 + 10);
}

test "LAN discovery advertises the status and accepts a LAN join" {
    var random: [2]u8 = undefined;
    std.testing.io.random(&random);
    const lan_port = 40000 + std.mem.readInt(u16, &random, .little) % 20000;
    const host = try start(.{ .lan_port = lan_port });
    defer host.destroy();
    host.setStatus("LAN test", "lan world", 10, 0);

    const io = host.io();
    const discovery = try nethernet.Discovery.listen(gpa, io, .{ .ip4 = .loopback(0) }, .{ .broadcast_endpoint = .{ .ip4 = .loopback(lan_port) } });
    defer discovery.destroy();
    const deadline = support.Deadline.in(io, 10_000);
    const server_id, const data = found: while (!deadline.expired()) {
        try discovery.request(.{ .ip4 = .loopback(lan_port) });
        _ = try discovery.poll(50);
        var servers = discovery.servers.iterator();
        while (servers.next()) |entry| {
            const response = entry.value_ptr.response orelse continue;
            // The advertisement follows setStatus on the worker's next tick.
            const decoded = try nethernet.ServerData.decode(response);
            if (std.mem.eql(u8, decoded.server_name, "LAN test")) break :found .{ entry.key_ptr.*, decoded };
        }
    } else return error.Timeout;
    try testing.expectEqualStrings("LAN test", data.server_name);
    try testing.expectEqualStrings("lan world", data.level_name);
    try testing.expectEqual(@as(i32, 10), data.max_player_count);
    try testing.expectEqual(@as(i32, @intCast(bedwire.protocol.protocol_version)), data.protocol);

    const client = try support.Client.adopt(io, try nethernet.dialLan(gpa, discovery, server_id, support.Client.options));
    defer client.destroy();
    const session = try support.expectConnect(host);
    try support.login(host, client, session, .zlib);
    var a: [64]u8 = undefined;
    const text = packets.raw(&a, packets.id(.text), "over lan");
    try host.send(session, &.{text});
    try testing.expectEqualSlices(u8, text, (try client.expectPackets(1, 5000))[0]);
}

test "raw batches are split natively and sent in order" {
    const host = try start(.{});
    defer host.destroy();
    const joined = try support.join(host, .zlib);
    defer joined.client.destroy();

    var first: [64]u8 = undefined;
    var second: [400]u8 = undefined;
    const body: [300]u8 = @splat('y');
    const a = packets.raw(&first, packets.id(.text), "short");
    const b = packets.raw(&second, packets.id(.text), &body);
    var batch: [512]u8 = undefined;
    var len: usize = 0;
    for ([_][]const u8{ a, b }) |packet| {
        len += bedwire.framing.varint.writeU32(batch[len..], @intCast(packet.len)) catch unreachable;
        @memcpy(batch[len..][0..packet.len], packet);
        len += packet.len;
    }
    try host.sendRawBatch(joined.session, batch[0..len]);
    const received = try joined.client.expectPackets(2, 5000);
    try testing.expectEqualSlices(u8, a, received[0]);
    try testing.expectEqualSlices(u8, b, received[1]);

    try testing.expectError(error.MalformedBatch, host.sendRawBatch(joined.session, batch[0 .. len - 1]));
    try testing.expectError(error.MalformedBatch, host.sendRawBatch(joined.session, &.{ 0x80, 0x80, 0x80, 0x80, 0x80, 0x01 }));
    try testing.expectError(error.EmptyBatch, host.sendRawBatch(joined.session, ""));
}

test "the unreliable channel works both ways when enabled" {
    const host = try start(.{ .unreliable_events = true });
    defer host.destroy();
    const joined = try support.join(host, .none);
    defer joined.client.destroy();

    try joined.client.connection.send("\x05voice", .unreliable);
    const event = try support.nextEvent(host, 5000);
    defer event.deinit();
    try testing.expectEqual(joined.session, event.unreliable.session);
    try testing.expectEqualStrings("\x05voice", event.unreliable.bytes);

    try host.sendUnreliable(joined.session, "\x06reply");
    const deadline = support.Deadline.in(host.io(), 5000);
    while (joined.client.unreliable.items.len == 0 and !deadline.expired()) joined.client.pump(5);
    try testing.expectEqualStrings("\x06reply", joined.client.unreliable.items[0]);
    try testing.expectError(error.EmptyBatch, host.sendUnreliable(joined.session, ""));
}

test "trusted proxies pass authenticated signaling and logins fall back to PHP" {
    const proxy = nethernet.IdentityKeyPair.generate(std.testing.io);
    const der = bedwire.crypto.spki.encode(proxy.public_key);
    const host = try start(.{ .authentication = true, .trusted_identity_keys = &.{&der} });
    defer host.destroy();

    const token = try nethernet.identity.serverToken(gpa, proxy, std.Io.Clock.real.now(host.io()).toSeconds());
    defer gpa.free(token);
    var options = support.Client.options;
    options.allow_anonymous = false;
    options.identity = .{ .key = proxy, .token = token };
    const client = try support.Client.connectWith(host.io(), host.local_address.getPort(), options);
    defer client.destroy();

    const connect = host_event: while (true) {
        const event = host.nextEvent() orelse {
            host.waitEvents(10);
            continue;
        };
        defer host.releaseEvents();
        break :host_event event.connect;
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&der, &digest, .{});
    try testing.expectEqualSlices(u8, &digest, connect.identity.?);
    try testing.expect(connect.issuer_verified);

    // A login Microsoft did not sign reaches PHP, which accepts it itself.
    try support.login(host, client, connect.session, .zlib);
    try testing.expectEqual(@as(u64, 1), host.statistics().login_fallbacks);
    try testing.expectEqual(@as(u64, 0), host.statistics().authentication_failures);
}
