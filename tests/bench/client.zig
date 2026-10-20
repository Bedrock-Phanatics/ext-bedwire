//! Load client for the PHP benchmark: `client <port> <sessions> <rate_hz> <seconds> <size>`.
//! It logs every session in, sends stamped packets for the duration and prints one JSON summary line.
const std = @import("std");
const bedwire = @import("bedwire");
const nethernet = @import("nethernet");
const peer_mod = @import("peer.zig");

const allocator = std.heap.smp_allocator;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 6) return error.Usage;
    const port = try std.fmt.parseInt(u16, args[1], 10);
    const sessions = try std.fmt.parseInt(usize, args[2], 10);
    const rate = try std.fmt.parseInt(u32, args[3], 10);
    const seconds = try std.fmt.parseInt(u32, args[4], 10);
    const size = @max(9, @min(try std.fmt.parseInt(usize, args[5], 10), 2048));

    var pool = try peer_mod.clientPool(allocator);
    defer pool.deinit();
    var wakeup: nethernet.Wakeup = .{};
    var latencies: std.ArrayList(u64) = .empty;
    defer latencies.deinit(allocator);
    var peers: std.ArrayList(*peer_mod.Peer) = .empty;
    defer {
        for (peers.items) |peer| peer.destroy();
        peers.deinit(allocator);
    }

    const join_start = peer_mod.nowNs(io);
    for (0..sessions) |_| {
        const peer = try peer_mod.Peer.connect(allocator, io, port, &pool, &wakeup);
        try peers.append(allocator, peer);
        try peer.login();
        peer.latencies = &latencies;
    }
    const join_ns = peer_mod.nowNs(io) - join_start;

    var storage: [2048]u8 = undefined;
    var sent: usize = 0;
    const interval = std.time.ns_per_s / @max(rate, 1);
    const start = peer_mod.nowNs(io);
    const end = start + @as(u64, seconds) * std.time.ns_per_s;
    var next = start;
    while (peer_mod.nowNs(io) < end) {
        const token = wakeup.prepare();
        if (rate != 0 and peer_mod.nowNs(io) >= next) {
            for (peers.items) |peer| {
                peer.send(&.{peer_mod.stamped(&storage, io, size)}) catch continue;
                sent += 1;
            }
            next += interval;
        }
        for (peers.items) |peer| peer.pump();
        const wait = (next -| peer_mod.nowNs(io)) / std.time.ns_per_us;
        wakeup.wait(io, token, .{ .duration = .{ .raw = .fromMicroseconds(@intCast(@max(wait, 50))), .clock = .awake } }) catch {};
    }
    // Let the last echoes arrive.
    const drain_end = peer_mod.nowNs(io) + 500 * std.time.ns_per_ms;
    while (latencies.items.len < sent and peer_mod.nowNs(io) < drain_end) {
        const token = wakeup.prepare();
        for (peers.items) |peer| peer.pump();
        wakeup.wait(io, token, .{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }) catch {};
    }

    std.mem.sort(u64, latencies.items, {}, std.sort.asc(u64));
    var out: [512]u8 = undefined;
    const line = try std.fmt.bufPrint(&out, "{{\"join_ms\":{d:.1},\"sent\":{d},\"received\":{d},\"p50_us\":{d:.0},\"p95_us\":{d:.0},\"p99_us\":{d:.0}}}\n", .{
        @as(f64, @floatFromInt(join_ns)) / 1e6,
        sent,
        latencies.items.len,
        percentile(latencies.items, 0.5),
        percentile(latencies.items, 0.95),
        percentile(latencies.items, 0.99),
    });
    var stdout = std.Io.File.stdout().writer(io, &.{});
    try stdout.interface.writeAll(line);
}

fn percentile(sorted: []const u64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    const index: usize = @intFromFloat(@min(@as(f64, @floatFromInt(sorted.len - 1)), p * @as(f64, @floatFromInt(sorted.len))));
    return @as(f64, @floatFromInt(sorted[index])) / 1000;
}
