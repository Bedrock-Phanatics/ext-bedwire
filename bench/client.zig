//! Client process for bench/boundary.php.
//! Usage: bedwire-bench-client <port> inbound <packets> <size> <per_frame>
//!        bedwire-bench-client <port> outbound <packets>
//! Prints the key DER and the server login packets as hex, logs in, runs, then reports one line.

const std = @import("std");
const peer_mod = @import("peer.zig");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.smp_allocator;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 4) return error.Usage;
    const port = try std.fmt.parseInt(u16, args[1], 10);
    const mode = args[2];
    const packets = try std.fmt.parseInt(usize, args[3], 10);

    var out_buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &out_buffer);
    const out = &stdout.interface;
    var storage: [3][256]u8 = undefined;
    try out.print("{x}\n", .{&peer_mod.publicKeyDer()});
    for (peer_mod.serverPackets(&storage)) |packet| try out.print("{x}\n", .{packet});
    try out.flush();

    var pool = try peer_mod.clientPool(allocator);
    defer pool.deinit();
    const peer = try peer_mod.Peer.connect(allocator, io, port, &pool);
    defer peer.destroy();
    try peer.login();

    if (std.mem.eql(u8, mode, "inbound")) {
        const size = try std.fmt.parseInt(usize, args[4], 10);
        const per_frame = try std.fmt.parseInt(usize, args[5], 10);
        var buffer: [16][2048]u8 = undefined;
        var frame: [16][]const u8 = undefined;
        var sent: usize = 0;
        while (sent < packets) {
            const n = @min(per_frame, packets - sent);
            for (frame[0..n], buffer[0..n]) |*packet, *bytes| packet.* = peer_mod.stamped(bytes, io, size);
            peer.send(frame[0..n]) catch {
                peer.pump(1);
                continue;
            };
            sent += n;
            peer.pump(0);
        }
        // Keep acknowledging until the server has drained everything.
        const end = peer_mod.nowNs(io) + 5 * std.time.ns_per_s;
        while (peer_mod.nowNs(io) < end) peer.pump(5);
        try out.print("sent {d}\n", .{sent});
    } else {
        var latencies: std.ArrayList(u64) = .empty;
        defer latencies.deinit(allocator);
        peer.latencies = &latencies;
        try out.print("ready\n", .{});
        try out.flush();
        const end = peer_mod.nowNs(io) + 60 * std.time.ns_per_s;
        while (latencies.items.len < packets and peer_mod.nowNs(io) < end) peer.pump(1);
        std.mem.sort(u64, latencies.items, {}, std.sort.asc(u64));
        try out.print("received {d} p50_us {d} p99_us {d}\n", .{
            latencies.items.len,
            peer_mod.percentile(latencies.items, 0.5) / 1000,
            peer_mod.percentile(latencies.items, 0.99) / 1000,
        });
    }
    try out.flush();
}
