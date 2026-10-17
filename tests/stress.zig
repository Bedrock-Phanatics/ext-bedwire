const std = @import("std");
const bedwire = @import("bedwire");
const raknet = @import("raknet");
const native = @import("native");
const support = @import("support.zig");
const packets = @import("packets.zig");
const options = @import("build_options");

const testing = std.testing;

fn requestFrame(storage: []u8) []const u8 {
    var packet: [16]u8 = undefined;
    const request = packets.request(&packet);
    storage[0] = 0xfe;
    const len = bedwire.framing.varint.writeU32(storage[1..], @intCast(request.len)) catch unreachable;
    @memcpy(storage[1 + len ..][0..request.len], request);
    return storage[0 .. 1 + len + request.len];
}

const Counts = struct { connects: usize = 0, packets: usize = 0, disconnects: usize = 0 };

fn drain(host: *native.Host, clients: []*raknet.Client, counts: *Counts, sessions: ?*std.ArrayList(u64)) !void {
    while (host.nextEvent()) |event| switch (event) {
        .connect => |c| {
            counts.connects += 1;
            if (sessions) |list| try list.append(testing.allocator, c.session);
        },
        .packet => counts.packets += 1,
        .disconnect => counts.disconnects += 1,
        else => {},
    };
    host.releaseEvents();
    for (clients) |client| {
        if (client.isClosed()) continue;
        _ = client.poll(.{ .duration = .{ .raw = .fromMilliseconds(0), .clock = .awake } }, client, ignore) catch {};
    }
    host.waitEvents(1);
}

fn ignore(_: *anyopaque, _: raknet.BorrowedPayload) error{ApplicationFailure}!void {}

fn churn(host: *native.Host, count: usize) !void {
    const io = host.io();
    var clients: std.ArrayList(*raknet.Client) = .empty;
    defer {
        for (clients.items) |client| client.destroy();
        clients.deinit(testing.allocator);
    }
    var sessions: std.ArrayList(u64) = .empty;
    defer sessions.deinit(testing.allocator);
    var counts: Counts = .{};

    var frame_storage: [64]u8 = undefined;
    const frame = requestFrame(&frame_storage);
    for (0..count) |_| {
        const client = try raknet.Client.connect(testing.allocator, io, .{ .ip4 = .loopback(host.local_address.getPort()) }, .{});
        try clients.append(testing.allocator, client);
        try client.send(frame, .reliable_ordered, 0);
        try drain(host, clients.items, &counts, &sessions);
    }
    var deadline = support.Deadline.in(io, 20_000);
    while (counts.packets < count) {
        if (deadline.expired()) return error.Timeout;
        try drain(host, clients.items, &counts, &sessions);
    }
    try testing.expectEqual(count, counts.connects);
    try testing.expectEqual(count, host.statistics().sessions);

    for (sessions.items, 0..) |session, i| {
        if (i % 2 == 0) try host.disconnect(session) else clients.items[i].closeNow();
    }
    deadline = support.Deadline.in(io, 20_000);
    while (counts.disconnects < count) {
        if (deadline.expired()) return error.Timeout;
        try drain(host, clients.items, &counts, null);
    }
    for (sessions.items) |session| try testing.expect(!host.isLive(session));
    try testing.expectEqual(@as(u64, 0), host.statistics().sessions);
}

test "connection churn at higher session counts leaves nothing behind" {
    const host = try native.Host.start(testing.allocator, support.config(.{ .max_sessions = 512, .event_queue_bytes = 4 * 1024 * 1024 }));
    defer host.destroy();
    for (0..options.stress_rounds) |_| try churn(host, 128);
}

test "start, traffic and stop cycles release every resource" {
    for (0..options.stress_rounds * 4) |_| {
        const host = try native.Host.start(testing.allocator, support.config(.{}));
        defer host.destroy();
        var frame_storage: [64]u8 = undefined;
        const frame = requestFrame(&frame_storage);
        var clients: [4]*raknet.Client = undefined;
        var connected: usize = 0;
        defer for (clients[0..connected]) |client| client.destroy();
        for (&clients) |*client| {
            client.* = try raknet.Client.connect(testing.allocator, host.io(), .{ .ip4 = .loopback(host.local_address.getPort()) }, .{});
            connected += 1;
            try client.*.send(frame, .reliable_ordered, 0);
        }
        var counts: Counts = .{};
        const deadline = support.Deadline.in(host.io(), 10_000);
        while (counts.packets < clients.len) {
            if (deadline.expired()) return error.Timeout;
            try drain(host, &clients, &counts, null);
        }
        host.stop(50);
        try drain(host, &.{}, &counts, null);
        try testing.expectEqual(clients.len, counts.disconnects);
    }
}

test "stopping during a flood neither deadlocks nor leaks" {
    const host = try native.Host.start(testing.allocator, support.config(.{ .packet_rate = 0 }));
    defer host.destroy();
    const client = try support.Client.connect(host.io(), host.local_address.getPort(), .{});
    defer client.destroy();
    const connect = try support.nextEvent(host, 5000, client);
    try support.login(host, client, connect.connect, .zlib);

    const Flood = struct {
        fn run(c: *support.Client, stop: *std.atomic.Value(bool)) void {
            var storage: [512]u8 = undefined;
            const packet = packets.raw(&storage, 1020, storage[2..]);
            while (!stop.load(.acquire)) {
                c.send(&.{ packet, packet, packet, packet }) catch {};
                c.pump(0);
            }
        }
    };
    var stop: std.atomic.Value(bool) = .init(false);
    const thread = try std.Thread.spawn(.{}, Flood.run, .{ client, &stop });
    defer thread.join();
    defer stop.store(true, .release);

    const deadline = support.Deadline.in(host.io(), 200);
    while (!deadline.expired()) {
        while (host.nextEvent()) |_| {}
        host.releaseEvents();
        host.waitEvents(5);
    }
    host.stop(100);
    try testing.expect(!host.running());
}
