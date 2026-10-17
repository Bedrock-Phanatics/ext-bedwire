//! Clients run in this process so process CPU includes them.

const std = @import("std");
const native = @import("native");
const peer_mod = @import("peer.zig");

const Peer = peer_mod.Peer;
const Ring = native.Ring;
const allocator = std.heap.smp_allocator;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const only = init.environ_map.get("BEDWIRE_BENCH");
    if (selected(only, "ring")) try ringThroughput(io);
    if (selected(only, "paced")) for ([_]usize{ 1, 100, 1000 }) |sessions| try paced(io, sessions, 64, 5);
    if (selected(only, "saturated")) {
        try saturated(io, 64);
        try saturated(io, 1200);
    }
}

fn selected(only: ?[]const u8, name: []const u8) bool {
    return only == null or std.mem.eql(u8, only.?, name);
}

fn ringThroughput(io: std.Io) !void {
    var ring = try Ring.init(allocator, 16 * 1024 * 1024);
    defer ring.deinit(allocator);
    const total = 20_000_000;
    const Producer = struct {
        fn run(r: *Ring) void {
            var i: u32 = 0;
            while (i < total) {
                const bytes = r.reserve(1, 64, 0) orelse {
                    r.publish();
                    std.atomic.spinLoopHint();
                    continue;
                };
                bytes[0] = @truncate(i);
                r.commit();
                i += 1;
                if (i % 64 == 0) r.publish();
            }
            r.publish();
        }
    };
    const start = peer_mod.nowNs(io);
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&ring});
    var seen: usize = 0;
    while (seen < total) {
        while (ring.next()) |_| seen += 1;
        ring.release();
    }
    thread.join();
    const ns = peer_mod.nowNs(io) - start;
    std.debug.print("ring  64 B records cross-thread: {d:.1} M/s\n", .{@as(f64, total) / (@as(f64, @floatFromInt(ns)) / 1e9) / 1e6});
}

const Clients = struct {
    io: std.Io,
    port: u16,
    count: usize,
    size: usize,
    rate_hz: u32,
    seconds: u32,
    saturate: bool = false,
    quiet: std.atomic.Value(bool) = .init(false),
    pool: @import("bedwire").BufferPool = undefined,
    peers: std.ArrayList(*Peer) = .empty,
    latencies: std.ArrayList(u64) = .empty,
    sent: usize = 0,
    ready: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    failed: ?anyerror = null,

    fn run(self: *Clients) void {
        self.runInner() catch |err| {
            self.failed = err;
        };
        self.ready.store(true, .release);
    }

    fn runInner(self: *Clients) !void {
        self.pool = try peer_mod.clientPool(allocator);
        for (0..self.count) |_| {
            const peer = try Peer.connect(allocator, self.io, self.port, &self.pool);
            try self.peers.append(allocator, peer);
            try peer.login();
            peer.latencies = &self.latencies;
        }
        self.ready.store(true, .release);
        var storage: [2048]u8 = undefined;
        const interval: u64 = if (self.rate_hz == 0) 0 else std.time.ns_per_s / self.rate_hz;
        var next = peer_mod.nowNs(self.io);
        while (!self.done.load(.acquire)) {
            if (!self.quiet.load(.acquire) and (self.saturate or peer_mod.nowNs(self.io) >= next)) {
                for (self.peers.items) |peer| {
                    peer.send(&.{peer_mod.stamped(&storage, self.io, self.size)}) catch continue;
                    self.sent += 1;
                }
                next += interval;
            }
            for (self.peers.items) |peer| peer.pump(0);
            if (!self.saturate) self.io.sleep(.fromMicroseconds(200), .awake) catch {};
        }
    }

    fn deinit(self: *Clients) void {
        for (self.peers.items) |peer| peer.destroy();
        self.peers.deinit(allocator);
        self.latencies.deinit(allocator);
        self.pool.deinit();
    }
};

fn respond(host: *native.Host, steps: *std.AutoHashMapUnmanaged(u64, u8), session: u64) !void {
    var storage: [3][256]u8 = undefined;
    const packets = peer_mod.serverPackets(&storage);
    const entry = try steps.getOrPut(allocator, session);
    if (!entry.found_existing) entry.value_ptr.* = 0;
    const step = entry.value_ptr.*;
    entry.value_ptr.* += 1;
    switch (step) {
        0 => _ = try host.send(session, &.{packets[0]}, false),
        1 => {
            const der = peer_mod.publicKeyDer();
            try host.acceptLogin(session, &der);
            _ = try host.send(session, &.{packets[1]}, false);
        },
        2 => _ = try host.send(session, &.{packets[2]}, false),
        else => {},
    }
}

fn startHost(sessions: usize) !*native.Host {
    return native.Host.start(allocator, .{
        .address = .{ .ip4 = .loopback(0) },
        .advertisement = "MCPE;bench;2193;1.0;0;10;1;w;Survival;1;19132;19133;",
        .max_sessions = @intCast(@max(sessions + 8, 16)),
        .encryption = false,
        .packet_rate = 0,
        .handshake_rate = 10_000,
        .max_batch_bytes = 256 * 1024,
        .event_queue_bytes = 64 * 1024 * 1024,
    });
}

fn workerCpuMs(host: *native.Host) u64 {
    const tid = host.shared.worker_thread.load(.acquire);
    var path: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&path, "/proc/self/task/{d}/stat", .{tid}) catch return 0;
    var buffer: [1024]u8 = undefined;
    const stat = std.Io.Dir.cwd().readFile(host.io(), name, &buffer) catch return 0;
    const len = stat.len;
    const close = std.mem.lastIndexOfScalar(u8, buffer[0..len], ')') orelse return 0;
    var fields = std.mem.tokenizeScalar(u8, buffer[close + 2 .. len], ' ');
    var i: usize = 0;
    var total: u64 = 0;
    while (fields.next()) |field| : (i += 1) {
        // utime and stime are fields 14 and 15, counting from field 3 here.
        if (i == 11 or i == 12) total += std.fmt.parseInt(u64, field, 10) catch 0;
        if (i == 12) break;
    }
    return total * 10;
}

fn cpuMs() u64 {
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const user: u64 = @intCast(usage.utime.sec * 1000 + @divTrunc(usage.utime.usec, 1000));
    const system: u64 = @intCast(usage.stime.sec * 1000 + @divTrunc(usage.stime.usec, 1000));
    return user + system;
}

fn paced(io: std.Io, sessions: usize, size: usize, seconds: u32) !void {
    const host = try startHost(sessions);
    defer host.destroy();
    const groups = @max(1, sessions / 100);
    const clients = try allocator.alloc(Clients, groups);
    defer allocator.free(clients);
    const threads = try allocator.alloc(std.Thread, groups);
    defer allocator.free(threads);
    var started: usize = 0;
    defer for (clients[0..started]) |*group| group.deinit();
    defer for (threads[0..started]) |thread| thread.join();
    defer for (clients[0..started]) |*group| group.done.store(true, .release);

    var steps: std.AutoHashMapUnmanaged(u64, u8) = .empty;
    defer steps.deinit(allocator);
    for (clients, threads, 0..) |*group, *thread, i| {
        const count = sessions / groups + @intFromBool(i < sessions % groups);
        group.* = .{ .io = io, .port = host.local_address.getPort(), .count = count, .size = size, .rate_hz = 20, .seconds = seconds };
        thread.* = try std.Thread.spawn(.{}, Clients.run, .{group});
        started += 1;
    }
    for (clients) |*group| {
        while (!group.ready.load(.acquire)) try drainLogin(host, &steps);
        if (group.failed) |err| return err;
    }

    var inbound: std.ArrayList(u64) = .empty;
    defer inbound.deinit(allocator);
    const cpu_start = cpuMs();
    const worker_start = workerCpuMs(host);
    const start = peer_mod.nowNs(io);
    const end = start + @as(u64, seconds) * std.time.ns_per_s;
    var events: usize = 0;
    while (peer_mod.nowNs(io) < end) {
        host.waitEvents(5);
        const now = peer_mod.nowNs(io);
        while (host.nextEvent()) |event| switch (event) {
            .packet => |p| if (p.bytes.len >= 10) {
                try inbound.append(allocator, now -| std.mem.readInt(u64, p.bytes[2..10], .little));
                events += 1;
            },
            else => {},
        };
        host.releaseEvents();
    }
    const cpu = cpuMs() - cpu_start;
    const worker_cpu = workerCpuMs(host) - worker_start;
    std.mem.sort(u64, inbound.items, {}, std.sort.asc(u64));
    std.debug.print("paced {d:>4} sessions x 20 Hz x {d} B: {d} events/s, inbound p50 {d} us p99 {d} us, worker CPU {d:.1}%, process CPU {d:.1}%\n", .{
        sessions,
        size,
        events / seconds,
        peer_mod.percentile(inbound.items, 0.5) / 1000,
        peer_mod.percentile(inbound.items, 0.99) / 1000,
        @as(f64, @floatFromInt(worker_cpu)) / @as(f64, @floatFromInt(seconds * 1000)) * 100,
        @as(f64, @floatFromInt(cpu)) / @as(f64, @floatFromInt(seconds * 1000)) * 100,
    });

    var storage: [2048]u8 = undefined;
    const ids = try sessionIds(allocator, &steps);
    defer allocator.free(ids);
    const out_end = peer_mod.nowNs(io) + 2 * std.time.ns_per_s;
    var tick = peer_mod.nowNs(io);
    while (peer_mod.nowNs(io) < out_end) {
        if (peer_mod.nowNs(io) >= tick) {
            for (ids) |id| _ = host.send(id, &.{peer_mod.stamped(&storage, io, size)}, false) catch {};
            tick += std.time.ns_per_s / 20;
        }
        while (host.nextEvent()) |_| {}
        host.releaseEvents();
        host.waitEvents(1);
    }
    for (clients) |*group| group.done.store(true, .release);
    for (threads) |thread| thread.join();
    var outbound: std.ArrayList(u64) = .empty;
    defer outbound.deinit(allocator);
    for (clients) |*group| try outbound.appendSlice(allocator, group.latencies.items);
    for (clients) |*group| group.deinit();
    started = 0;
    std.mem.sort(u64, outbound.items, {}, std.sort.asc(u64));
    std.debug.print("      outbound p50 {d} us p99 {d} us over {d} packets\n", .{
        peer_mod.percentile(outbound.items, 0.5) / 1000,
        peer_mod.percentile(outbound.items, 0.99) / 1000,
        outbound.items.len,
    });
}

fn saturated(io: std.Io, size: usize) !void {
    const host = try startHost(1);
    defer host.destroy();
    var clients: Clients = .{ .io = io, .port = host.local_address.getPort(), .count = 1, .size = size, .rate_hz = 0, .seconds = 3, .saturate = true };
    defer clients.deinit();
    const thread = try std.Thread.spawn(.{}, Clients.run, .{&clients});
    defer thread.join();
    defer clients.done.store(true, .release);

    var steps: std.AutoHashMapUnmanaged(u64, u8) = .empty;
    defer steps.deinit(allocator);
    while (!clients.ready.load(.acquire)) try drainLogin(host, &steps);
    if (clients.failed) |err| return err;

    const start = peer_mod.nowNs(io);
    var events: usize = 0;
    var bytes: usize = 0;
    while (peer_mod.nowNs(io) - start < 3 * std.time.ns_per_s) {
        host.waitEvents(5);
        while (host.nextEvent()) |event| switch (event) {
            .packet => |p| {
                events += 1;
                bytes += p.bytes.len;
            },
            .disconnect => |d| std.debug.print("  disconnected: {t}\n", .{d.reason}),
            else => {},
        };
        host.releaseEvents();
    }
    std.debug.print("inbound saturated {d} B: {d} packets/s ({d:.1} MiB/s)\n", .{ size, events / 3, @as(f64, @floatFromInt(bytes)) / 3 / 1024 / 1024 });

    clients.quiet.store(true, .release);

    const ids = try sessionIds(allocator, &steps);
    defer allocator.free(ids);
    var storage: [2048]u8 = undefined;
    const packet = peer_mod.stamped(&storage, io, size);
    for ([_]usize{ 1, 16 }) |per_call| {
        var batch: [16][]const u8 = @splat(packet);
        var calls: usize = 0;
        var spent: u64 = 0;
        for (0..50) |_| {
            for (0..128) |_| {
                const before = peer_mod.nowNs(io);
                _ = try host.send(ids[0], batch[0..per_call], false);
                spent += peer_mod.nowNs(io) - before;
                calls += 1;
            }
            io.sleep(.fromMilliseconds(20), .awake) catch {};
            while (host.nextEvent()) |_| {}
            host.releaseEvents();
        }
        std.debug.print("send {d:>2} x {d} B per call: {d} ns/call, {d} ns/packet\n", .{ per_call, size, spent / calls, spent / calls / per_call });
    }
}

fn drainLogin(host: *native.Host, steps: *std.AutoHashMapUnmanaged(u64, u8)) !void {
    host.waitEvents(2);
    while (host.nextEvent()) |event| switch (event) {
        .packet => |p| try respond(host, steps, p.session),
        else => {},
    };
    host.releaseEvents();
}

fn sessionIds(gpa: std.mem.Allocator, steps: *std.AutoHashMapUnmanaged(u64, u8)) ![]u64 {
    const ids = try gpa.alloc(u64, steps.count());
    var keys = steps.keyIterator();
    var i: usize = 0;
    while (keys.next()) |key| : (i += 1) ids[i] = key.*;
    return ids;
}
