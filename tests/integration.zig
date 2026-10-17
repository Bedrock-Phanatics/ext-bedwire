const std = @import("std");
const bedwire = @import("bedwire");
const raknet = @import("raknet");
const native = @import("native");
const support = @import("support.zig");

const testing = std.testing;
const Client = support.Client;

fn expectConnect(host: *native.Host, client: *Client) !u64 {
    const event = try support.nextEvent(host, 5000, client);
    if (event != .connect) return error.UnexpectedEvent;
    return event.connect;
}

fn expectDisconnect(host: *native.Host, client: ?*Client, session: u64, reason: native.Reason) !void {
    const deadline = support.Deadline.in(host.io(), 15_000);
    while (!deadline.expired()) {
        const event = (if (client) |c| support.nextEvent(host, 100, c) else support.nextEvent(host, 100, null)) catch |err| switch (err) {
            error.Timeout => continue,
            else => return err,
        };
        defer event.deinit();
        switch (event) {
            .disconnect => |d| {
                try testing.expectEqual(session, d.session);
                try testing.expectEqual(reason, d.reason);
                return;
            },
            .packet, .receipt_ack, .receipt_failed => {},
            else => return error.UnexpectedEvent,
        }
    }
    return error.Timeout;
}

fn startHost(overrides: anytype) !*native.Host {
    return native.Host.start(testing.allocator, support.config(overrides));
}

test "a client logs in with encryption and exchanges batched gameplay" {
    const host = try startHost(.{});
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    const session = try expectConnect(host, client);
    try testing.expect(host.isLive(session));

    try support.login(host, client, session, .zlib);

    var storage: [3][64]u8 = undefined;
    var packets: [3][]const u8 = undefined;
    for (&packets, 0..) |*packet, i| packet.* = support.raw(&storage[i], @intCast(1020 + i), "gameplay");
    _ = try host.send(session, &packets, false);
    const got = try client.expectPackets(3, 5000);
    for (packets, got) |sent, received| try testing.expectEqualSlices(u8, sent, received);
    client.clear();

    var big: [40_000]u8 = undefined;
    for (&big, 0..) |*byte, i| byte.* = @truncate(i *% 7);
    const large = support.raw(&big, 1023, big[4..]);
    try client.send(&.{ packets[0], large, packets[1] });
    try support.expectPacket(host, client, session, packets[0]);
    try support.expectPacket(host, client, session, large);
    try support.expectPacket(host, client, session, packets[1]);

    const receipt = try host.send(session, &.{packets[2]}, true);
    try testing.expect(receipt != 0);
    const ack = try support.nextEvent(host, 5000, client);
    try testing.expectEqual(support.Owned{ .receipt_ack = receipt }, ack);

    var disconnect: [64]u8 = undefined;
    _ = try host.send(session, &.{support.typed(&disconnect, .{ .disconnect = .{ .reason = .unknown, .messages = .empty } })}, false);
    try host.disconnect(session);
    try expectDisconnect(host, client, session, .server);
    try testing.expect(!host.isLive(session));
    try testing.expectError(error.Closed, host.send(session, &.{packets[0]}, false));
    try testing.expectError(error.Closed, host.disconnect(session));

    const stats = host.statistics();
    try testing.expect(stats.bytes_received > 0 and stats.bytes_sent > 0);
}

test "snappy compression works through the worker" {
    const host = try startHost(.{});
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    const session = try expectConnect(host, client);
    try support.login(host, client, session, .snappy);

    var storage: [2048]u8 = undefined;
    const packet = support.raw(&storage, 1021, &(@as([2000]u8, @splat('a'))));
    _ = try host.send(session, &.{packet}, false);
    try testing.expectEqualSlices(u8, packet, (try client.expectPackets(1, 5000))[0]);
}

test "stale session IDs never reach a reused slot" {
    const host = try startHost(.{ .max_sessions = 1 });
    defer host.destroy();

    const first = try Client.connect(host.io(), host.local_address.getPort(), .{});
    const old = try expectConnect(host, first);
    first.rak.closeNow();
    first.destroy();
    try expectDisconnect(host, null, old, .remote);

    const second = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer second.destroy();
    const fresh = try expectConnect(host, second);
    try testing.expect(old != fresh);
    try testing.expectEqual(old & 0xffff, fresh & 0xffff);
    try testing.expect(!host.isLive(old));
    try testing.expect(host.isLive(fresh));
    var storage: [8]u8 = undefined;
    try testing.expectError(error.Closed, host.send(old, &.{support.raw(&storage, 1020, "x")}, false));
    try testing.expectError(error.Closed, host.send(0, &.{support.raw(&storage, 1020, "x")}, false));
    try testing.expectError(error.Closed, host.send(std.math.maxInt(u64), &.{support.raw(&storage, 1020, "x")}, false));
}

test "malformed batches close the session with a protocol reason" {
    const host = try startHost(.{});
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    const session = try expectConnect(host, client);

    try client.sendRaw(&.{ 0xfe, 0xff, 0xff, 0xff, 0xff, 0x0f });
    try expectDisconnect(host, client, session, .protocol);
    try testing.expectEqual(@as(u64, 1), host.statistics().protocol_disconnects);
}

test "out-of-stage packets from the client are refused" {
    const host = try startHost(.{});
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    const session = try expectConnect(host, client);

    // A Login before network settings.
    try client.sendRaw(&.{ 0xfe, 0x02, 0x01, 0x00 });
    try expectDisconnect(host, client, session, .protocol);
}

test "packets the server stage forbids are dropped, not sent" {
    const host = try startHost(.{});
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    const session = try expectConnect(host, client);

    var storage: [16]u8 = undefined;
    _ = try host.send(session, &.{support.raw(&storage, 1020, "early")}, false);
    const receipt = try host.send(session, &.{support.raw(&storage, 1020, "early")}, true);
    const event = try support.nextEvent(host, 5000, client);
    try testing.expectEqual(support.Owned{ .receipt_failed = receipt }, event);
    try testing.expectEqual(@as(usize, 0), client.received.items.len);
    try testing.expect(host.statistics().packets_rejected >= 2);
    try testing.expect(host.isLive(session));
}

test "per-session packet rate limit disconnects floods" {
    const host = try startHost(.{ .packet_rate = 20 });
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    const session = try expectConnect(host, client);
    try support.login(host, client, session, .zlib);

    var storage: [8]u8 = undefined;
    const packet = support.raw(&storage, 1020, "x");
    var batch: [64][]const u8 = @splat(packet);
    try client.send(&batch);
    try expectDisconnect(host, client, session, .overload);
    try testing.expectEqual(@as(u64, 1), host.statistics().overload_disconnects);
}

test "a full event queue disconnects the flooding session and still reports it" {
    const host = try startHost(.{ .packet_rate = 0, .event_queue_bytes = 4 * (64 * 1024 + 64) });
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    const session = try expectConnect(host, client);
    try support.login(host, client, session, .zlib);

    // Nothing drains while the client floods.
    var storage: [8 * 1024]u8 = undefined;
    const packet = support.raw(&storage, 1020, storage[4..]);
    var sent: usize = 0;
    while (sent < 200) : (sent += 1) {
        client.send(&.{packet}) catch break;
        client.pump(1);
    }
    const deadline = support.Deadline.in(host.io(), 10_000);
    while (host.isLive(session) and !deadline.expired()) client.pump(5);
    try testing.expect(!host.isLive(session));
    try expectDisconnect(host, null, session, .overload);
}

test "receipts are bounded on the PHP side" {
    const host = try startHost(.{ .max_receipts = 2 });
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    const session = try expectConnect(host, client);
    try support.login(host, client, session, .zlib);

    var storage: [8]u8 = undefined;
    const packet = support.raw(&storage, 1020, "r");
    const a = try host.send(session, &.{packet}, true);
    const b = try host.send(session, &.{packet}, true);
    try testing.expectError(error.Backpressure, host.send(session, &.{packet}, true));
    var acked: usize = 0;
    while (acked < 2) {
        const event = try support.nextEvent(host, 5000, client);
        switch (event) {
            .receipt_ack => |id| {
                try testing.expect(id == a or id == b);
                acked += 1;
            },
            else => return error.UnexpectedEvent,
        }
    }
    _ = try host.send(session, &.{packet}, true);
}

test "pending receipts fail when the session closes" {
    const host = try startHost(.{});
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    const session = try expectConnect(host, client);
    try support.login(host, client, session, .zlib);
    // Vanish without a disconnect notification, so the receipt waits for the idle timeout.
    client.destroy();

    var storage: [8]u8 = undefined;
    const receipt = host.send(session, &.{support.raw(&storage, 1020, "lost")}, true) catch |err| switch (err) {
        error.Closed => return,
        else => return err,
    };
    var failed = false;
    var disconnected = false;
    const deadline = support.Deadline.in(host.io(), 20_000);
    while (!(failed and disconnected) and !deadline.expired()) {
        const event = support.nextEvent(host, 100, null) catch continue;
        switch (event) {
            .receipt_failed => |id| failed = id == receipt,
            .receipt_ack => return error.UnexpectedEvent,
            .disconnect => disconnected = true,
            else => event.deinit(),
        }
    }
    try testing.expect(failed and disconnected);
}

test "invalid send arguments are rejected before queueing" {
    const host = try startHost(.{});
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    const session = try expectConnect(host, client);

    try testing.expectError(error.EmptyBatch, host.send(session, &.{}, false));
    try testing.expectError(error.EmptyBatch, host.send(session, &.{""}, false));
    const huge = try testing.allocator.alloc(u8, 70 * 1024);
    defer testing.allocator.free(huge);
    @memset(huge, 1);
    try testing.expectError(error.TooLarge, host.send(session, &.{huge}, false));
    var many: [native.max_packets_per_batch + 1][]const u8 = @splat("x");
    try testing.expectError(error.TooManyPackets, host.send(session, &many, false));
    const key: [32]u8 = @splat(0);
    try testing.expectError(error.EmptyBatch, host.enableEncryption(session, "", &key));
    try testing.expectError(error.TooLarge, host.setAdvertisement(""));
}

test "encryption and login commands in the wrong stage close the session" {
    const host = try startHost(.{});
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    const session = try expectConnect(host, client);

    var storage: [64]u8 = undefined;
    const key: [32]u8 = @splat(3);
    try host.enableEncryption(session, support.typed(&storage, .{ .server_to_client_handshake = .{ .handshake_web_token = "x" } }), &key);
    try expectDisconnect(host, client, session, .protocol);

    const other = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer other.destroy();
    const second = try expectConnect(host, other);
    try host.acceptLogin(second, "not a key");
    try expectDisconnect(host, other, second, .protocol);
}

test "logins without encryption need the verified client key" {
    const host = try startHost(.{ .encryption = false });
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    client.session.policy.encryption = .optional;
    const session = try expectConnect(host, client);

    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    const request = support.typed(&a, .{ .request_network_settings = .{ .client_network_version = bedwire.protocol.Current.protocol_number } });
    try client.send(&.{request});
    try support.expectPacket(host, client, session, request);
    _ = try host.send(session, &.{support.networkSettings(&b, .zlib)}, false);
    _ = try client.expectPackets(1, 5000);
    const login_packet = support.typed(&a, .{ .login = .{ .client_network_version = bedwire.protocol.Current.protocol_number, .connection_request = "fixture" } });
    try client.send(&.{login_packet});
    try support.expectPacket(host, client, session, login_packet);

    const der = bedwire.crypto.spki.encode(client.key.public_key);
    try host.acceptLogin(session, &der);
    _ = try host.send(session, &.{support.resourcePacksInfo(&b)}, false);
    try client.session.advance(.resource_packs);
    _ = try client.expectPackets(2, 5000);
}

test "stop closes live sessions with a shutdown reason and is idempotent" {
    const host = try startHost(.{});
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    const session = try expectConnect(host, client);

    host.stop(200);
    host.stop(200);
    try testing.expect(!host.running());
    var storage: [8]u8 = undefined;
    try testing.expectError(error.Closed, host.send(session, &.{support.raw(&storage, 1020, "x")}, false));
    try testing.expectError(error.Closed, host.setAdvertisement("MCPE;x"));
    try expectDisconnect(host, null, session, .shutdown);
    try testing.expect(!host.isLive(session));
}

test "advertisement updates reach the next pong" {
    const host = try startHost(.{});
    defer host.destroy();
    var buffer: [1500]u8 = undefined;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(host.local_address.getPort()) };
    try testing.expectEqualStrings(support.advertisement, (try raknet.ping(host.io(), address, &buffer, 2000)).advertisement);

    const next = "MCPE;updated;2193;1.0;5;10;1;test;Survival;1;19132;19133;";
    try host.setAdvertisement(next);
    const deadline = support.Deadline.in(host.io(), 5000);
    while (!deadline.expired()) {
        if (std.mem.eql(u8, next, (try raknet.ping(host.io(), address, &buffer, 2000)).advertisement)) return;
    }
    return error.Timeout;
}

test "blocked addresses cannot connect until unblocked" {
    const host = try startHost(.{});
    defer host.destroy();
    try host.blockAddress(.{ .ip4 = .loopback(0) }, 60);
    var buffer: [1500]u8 = undefined;
    const address: std.Io.net.IpAddress = .{ .ip4 = .loopback(host.local_address.getPort()) };
    // The worker applies commands asynchronously.
    const settle = support.Deadline.in(host.io(), 200);
    while (!settle.expired()) host.waitEvents(10);
    try testing.expectError(error.Timeout, raknet.ping(host.io(), address, &buffer, 300));

    try host.unblockAddress(.{ .ip4 = .loopback(0) });
    const deadline = support.Deadline.in(host.io(), 5000);
    while (!deadline.expired()) {
        _ = raknet.ping(host.io(), address, &buffer, 300) catch continue;
        return;
    }
    return error.Timeout;
}

test "raw prefixes are forwarded and answered without RakNet" {
    const host = try startHost(.{ .raw_prefixes = &.{"\xfe\xfd"} });
    defer host.destroy();
    const io = host.io();
    const local: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var socket = try local.bind(io, .{ .mode = .dgram, .protocol = .udp });
    defer socket.close(io);
    const server: std.Io.net.IpAddress = .{ .ip4 = .loopback(host.local_address.getPort()) };
    try socket.send(io, &server, "\xfe\xfd\x09query");

    const event = try support.nextEvent(host, 5000, null);
    defer event.deinit();
    try testing.expectEqualSlices(u8, "\xfe\xfd\x09query", event.raw.bytes);
    try testing.expectEqual(socket.address.getPort(), event.raw.port);

    try host.sendRaw(.{ .ip4 = .loopback(event.raw.port) }, "\x09reply");
    var buffer: [64]u8 = undefined;
    const reply = try socket.receiveTimeout(io, &buffer, .{ .duration = .{ .raw = .fromMilliseconds(5000), .clock = .awake } });
    try testing.expectEqualSlices(u8, "\x09reply", reply.data);
}

test "ping events report transport RTT" {
    const host = try startHost(.{ .ping_interval_ms = 100 });
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    const session = try expectConnect(host, client);
    try support.login(host, client, session, .zlib);

    const deadline = support.Deadline.in(host.io(), 5000);
    while (!deadline.expired()) {
        client.pump(5);
        while (host.nextEvent()) |event| switch (event) {
            .ping => |p| {
                try testing.expectEqual(session, p.session);
                host.releaseEvents();
                return;
            },
            else => {},
        };
        host.releaseEvents();
    }
    return error.Timeout;
}

test "invalid configurations are refused" {
    try testing.expectError(error.InvalidConfig, native.Host.start(testing.allocator, support.config(.{ .max_sessions = 0 })));
    try testing.expectError(error.InvalidConfig, native.Host.start(testing.allocator, support.config(.{ .advertisement = "" })));
    try testing.expectError(error.InvalidConfig, native.Host.start(testing.allocator, support.config(.{ .raw_prefixes = &.{""} })));
    try testing.expectError(error.InvalidConfig, native.Host.start(testing.allocator, support.config(.{ .event_queue_bytes = 1024 })));
}

test "a port already in use fails cleanly" {
    const host = try startHost(.{});
    defer host.destroy();
    try testing.expect(std.meta.isError(native.Host.start(testing.allocator, support.config(.{ .address = host.local_address }))));
}

test "queued single sends to one session coalesce without reordering" {
    const host = try startHost(.{});
    defer host.destroy();
    const client = try Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    const session = try expectConnect(host, client);
    try support.login(host, client, session, .zlib);
    const before = host.statistics().batches_sent;

    const count = 2000;
    var storage: [8]u8 = undefined;
    for (0..count) |i| {
        var body: [4]u8 = undefined;
        std.mem.writeInt(u32, &body, @intCast(i), .little);
        _ = try host.send(session, &.{support.raw(&storage, 1020, &body)}, false);
    }
    const got = try client.expectPackets(count, 10_000);
    for (got, 0..) |packet, i| try testing.expectEqual(@as(u32, @intCast(i)), std.mem.readInt(u32, packet[2..6], .little));
    try testing.expect(host.isLive(session));
    try testing.expect(host.statistics().batches_sent - before < count);
}
