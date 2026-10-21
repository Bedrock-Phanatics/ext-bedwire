const std = @import("std");
const native = @import("native");
const build_options = @import("build_options");
const packets = @import("packets.zig");
const support = @import("support.zig");

const testing = std.testing;
const gpa = testing.allocator;

test "connection churn leaves nothing behind" {
    const host = try native.Host.start(gpa, support.config(.{ .max_sessions = 8 }));
    defer host.destroy();
    for (0..build_options.stress_rounds * 4) |_| {
        const joined = try support.join(host, .zlib);
        joined.client.destroy();
        try support.expectDisconnect(host, joined.session, .remote);
    }
    try testing.expectEqual(@as(u64, 0), host.statistics().sessions);
}

test "start, traffic and stop cycles release every resource" {
    for (0..build_options.stress_rounds) |_| {
        const host = try native.Host.start(gpa, support.config(.{}));
        defer host.destroy();
        const joined = try support.join(host, .snappy);
        defer joined.client.destroy();
        var a: [64]u8 = undefined;
        for (0..50) |_| try host.send(joined.session, &.{packets.raw(&a, packets.id(.text), "cycle")});
        _ = try joined.client.expectPackets(50, 5000);
        host.stop(500);
    }
}

test "stopping during a flood neither deadlocks nor leaks" {
    const host = try native.Host.start(gpa, support.config(.{ .packet_rate = 0 }));
    defer host.destroy();
    const joined = try support.join(host, .none);
    defer joined.client.destroy();
    var a: [256]u8 = undefined;
    const body: [200]u8 = @splat('x');
    const text = packets.raw(&a, packets.id(.text), &body);
    for (0..500) |_| {
        joined.client.send(&.{text}) catch break;
        host.send(joined.session, &.{text}) catch {};
    }
    host.stop(0);
    try testing.expect(!host.running());
}

test "several clients join concurrently and keep their own ordering" {
    const host = try native.Host.start(gpa, support.config(.{}));
    defer host.destroy();
    var clients: [4]struct { client: *support.Client, session: u64 } = undefined;
    for (&clients) |*entry| {
        const joined = try support.join(host, .zlib);
        entry.* = .{ .client = joined.client, .session = joined.session };
    }
    defer for (clients) |entry| entry.client.destroy();

    var storage: [4][50][16]u8 = undefined;
    for (clients, 0..) |entry, c| {
        for (0..50) |i| try host.send(entry.session, &.{packets.raw(&storage[c][i], packets.id(.text), &.{ @intCast(c), @intCast(i) })});
    }
    for (clients, 0..) |entry, c| {
        const received = try entry.client.expectPackets(50, 5000);
        for (received, 0..) |packet, i| {
            try testing.expectEqual(@as(u8, @intCast(c)), packet[packet.len - 2]);
            try testing.expectEqual(@as(u8, @intCast(i)), packet[packet.len - 1]);
        }
    }
}

test "servers whose lifetimes overlap keep the process alive" {
    for (0..build_options.stress_rounds) |_| {
        const first = try native.Host.start(gpa, support.config(.{}));
        const second = try native.Host.start(gpa, support.config(.{}));
        first.destroy();
        const joined = try support.join(second, .none);
        joined.client.destroy();
        second.destroy();
    }
}
