//! Native benchmarks. Pass section names (codec, session, nbt, ring, transport) to run a subset.
const std = @import("std");
const bedwire = @import("bedwire");
const nethernet = @import("nethernet");
const nbt = @import("nbt");
const native = @import("native");
const peer_mod = @import("peer.zig");

const protocol = bedwire.protocol;
const Peer = peer_mod.Peer;
const allocator = std.heap.smp_allocator;
const nowNs = peer_mod.nowNs;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const only = args[1..];
    if (selected(only, "codec")) try codec(io);
    if (selected(only, "session")) try session(io);
    if (selected(only, "nbt")) try nbtBench(io);
    if (selected(only, "ring")) try ringThroughput(io);
    if (selected(only, "transport")) {
        for ([_]usize{ 1, 50, 200 }) |count| try transport(io, count, 20, 5);
        try idle(io, 50, 5);
    }
}

fn selected(only: []const []const u8, name: []const u8) bool {
    if (only.len == 0) return true;
    for (only) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

fn report(name: []const u8, ops: usize, ns: u64, bytes: usize) void {
    const seconds = @as(f64, @floatFromInt(ns)) / 1e9;
    const per_op = @as(f64, @floatFromInt(ns)) / @as(f64, @floatFromInt(ops));
    if (bytes == 0) {
        std.debug.print("{s: <44} {d: >10.1} ns/op {d: >10.2} M ops/s\n", .{ name, per_op, @as(f64, @floatFromInt(ops)) / seconds / 1e6 });
    } else {
        std.debug.print("{s: <44} {d: >10.1} ns/op {d: >10.1} MB/s\n", .{ name, per_op, @as(f64, @floatFromInt(bytes)) / seconds / 1e6 });
    }
}

/// Repeats `body` until about 300 ms have passed and reports the mean.
fn measure(io: std.Io, name: []const u8, bytes_per_op: usize, context: anytype, comptime body: fn (@TypeOf(context)) anyerror!void) !void {
    for (0..1000) |_| try body(context);
    var ops: usize = 0;
    const start = nowNs(io);
    var elapsed: u64 = 0;
    while (elapsed < 300 * std.time.ns_per_ms) {
        for (0..256) |_| try body(context);
        ops += 256;
        elapsed = nowNs(io) - start;
    }
    report(name, ops, elapsed, bytes_per_op * ops);
}

const Samples = struct {
    move: []const u8,
    text: []const u8,
    chunk: []const u8,

    fn init(storage: *[3][24 * 1024]u8) Samples {
        var chunk_data: [16 * 1024]u8 = undefined;
        // Chunk payloads are mostly palette runs, which compress like this.
        for (&chunk_data, 0..) |*byte, i| byte.* = if (i % 64 < 48) 0 else @truncate(i *% 2654435761 >> 13);
        return .{
            .move = peer_mod.typed(&storage[0], .{ .move_player = .{
                .player_runtime_id = 81234,
                .position = .{ .x = 128.5, .y = 64, .z = -312.25 },
                .rotation = .{ .x = 12.5, .y = 270 },
                .y_head_rotation = 270,
                .position_mode = @fromBackingInt(0),
                .on_ground = true,
                .riding_runtime_id = 0,
                .teleport_data = null,
                .tick = 123456,
            } }),
            .text = peer_mod.typed(&storage[1], .{ .text = .{
                .localize = false,
                .body = .{ .author_and_message = .{ .message_type = .chat, .player_name = "Steve", .message = "hello from the benchmark, this is a chat line" } },
                .senders_xuid = "2535412345678901",
                .platform_id = "",
                .filtered_message = null,
            } }),
            .chunk = peer_mod.typed(&storage[2], .{ .level_chunk = .{
                .chunk_position = .{ .x = 10, .z = -4 },
                .dimension_id = 0,
                .sub_chunks_count = 8,
                .client_request_sub_chunk_limit = null,
                .cache_enabled = false,
                .cache_metadata = .empty,
                .serialized_chunk_data = &chunk_data,
            } }),
        };
    }
};

fn codec(io: std.Io) !void {
    std.debug.print("\n== protocol-zig codec (native, borrowed decode) ==\n", .{});
    var storage: [3][24 * 1024]u8 = undefined;
    const samples = Samples.init(&storage);
    const Case = struct { bytes: []const u8, out: [24 * 1024]u8 = undefined };
    inline for (.{ "move_player", "text", "level_chunk 16 KiB" }, .{ samples.move, samples.text, samples.chunk }) |name, bytes| {
        var case: Case = .{ .bytes = bytes };
        try measure(io, "decode " ++ name, bytes.len, &case, struct {
            fn run(c: *Case) !void {
                const decoded = try protocol.Current.decodeBorrowed(c.bytes, .{});
                std.mem.doNotOptimizeAway(&decoded);
            }
        }.run);
        try measure(io, "decode+encode " ++ name, bytes.len, &case, struct {
            fn run(c: *Case) !void {
                const decoded = try protocol.typed.decode(c.bytes, .{});
                var writer = protocol.Writer.init(&c.out);
                try protocol.typed.encode(&writer, decoded);
                std.mem.doNotOptimizeAway(writer.written().ptr);
            }
        }.run);
    }
}

const SessionCase = struct {
    server: *bedwire.Session,
    client: *bedwire.Session,
    batch: []const []const u8,
    bytes: usize,
};

fn session(io: std.Io) !void {
    std.debug.print("\n== Bedwire sessions, gameplay mix of 20 moves, 5 chat lines and 1 chunk ==\n", .{});
    var storage: [3][24 * 1024]u8 = undefined;
    const samples = Samples.init(&storage);
    var batch: [26][]const u8 = undefined;
    for (batch[0..20]) |*packet| packet.* = samples.move;
    for (batch[20..25]) |*packet| packet.* = samples.text;
    batch[25] = samples.chunk;
    var total: usize = 0;
    for (batch) |packet| total += packet.len;

    var pool = try bedwire.BufferPool.init(allocator, .{ .max_frame_bytes = 4 * 1024 * 1024, .max_batch_bytes = 1024 * 1024, .max_packet_bytes = 1024 * 1024 }, .{ .rx_slots = 2, .tx_slots = 2 });
    defer pool.deinit();
    const policy: bedwire.SessionPolicy = .{ .encryption = .disabled, .batch_header = false };
    inline for (.{ .deflate, .snappy, .none }) |algorithm| {
        var server = try bedwire.Session.init(.server, .{ .pool = &pool, .policy = policy });
        defer server.deinit();
        var client = try bedwire.Session.init(.client, .{ .pool = &pool, .policy = policy });
        defer client.deinit();
        server.state = .in_game;
        client.state = .in_game;
        server.compression = .init(server.features());
        try server.compression.negotiate(algorithm, 256);
        client.compression = .init(client.features());
        try client.compression.negotiate(algorithm, 256);

        var case: SessionCase = .{ .server = &server, .client = &client, .batch = &batch, .bytes = total };
        const frame = try server.encode(&batch);
        const wire = frame.bytes.len;
        frame.release();
        std.debug.print("{s}: {d} B of packets -> {d} B on the wire ({d:.1}%)\n", .{ @tagName(algorithm), total, wire, 100 * @as(f64, @floatFromInt(wire)) / @as(f64, @floatFromInt(total)) });
        try measure(io, "  encode batch " ++ @tagName(algorithm), total, &case, struct {
            fn run(c: *SessionCase) !void {
                const out = try c.server.encode(c.batch);
                out.release();
            }
        }.run);
        try measure(io, "  encode + ingest batch " ++ @tagName(algorithm), total, &case, struct {
            fn run(c: *SessionCase) !void {
                const out = try c.server.encode(c.batch);
                defer out.release();
                var packets = try c.client.ingest(out.bytes);
                defer packets.deinit();
                while (packets.next()) |packet| std.mem.doNotOptimizeAway(packet.bytes.ptr);
            }
        }.run);
    }
}

fn nbtBench(io: std.Io) !void {
    std.debug.print("\n== NBT, a chest block entity with 27 enchanted items ==\n", .{});
    var compound = nbt.builder.Compound.init(allocator);
    defer compound.deinit();
    try compound.add("id", try nbt.builder.string(allocator, "Chest"));
    try compound.add("x", .{ .int = 100 });
    try compound.add("y", .{ .int = 64 });
    try compound.add("z", .{ .int = -20 });
    const items = try allocator.alloc(nbt.Tag, 27);
    for (items, 0..) |*item, i| {
        var entry = nbt.builder.Compound.init(allocator);
        errdefer entry.deinit();
        try entry.add("Name", try nbt.builder.string(allocator, "minecraft:diamond_sword"));
        try entry.add("Count", .{ .byte = 1 });
        try entry.add("Slot", .{ .byte = @intCast(i) });
        try entry.add("Damage", .{ .short = 0 });
        var tag = nbt.builder.Compound.init(allocator);
        errdefer tag.deinit();
        try tag.add("Unbreakable", .{ .byte = 1 });
        try tag.add("display", .{ .compound = .{ .entries = &.{} } });
        try entry.add("tag", try tag.finish());
        item.* = try entry.finish();
    }
    try compound.add("Items", .{ .list = .{ .element_type = .compound, .items = items } });
    var document = try nbt.Document.init(allocator, "", try compound.finish());
    defer document.deinit(allocator);

    inline for (.{ native.nbt.Format.bedrock, native.nbt.Format.network }) |format| {
        const options = native.nbt.options(format, native.nbt.max_depth);
        const bytes = try nbt.serialize(allocator, document, options);
        defer allocator.free(bytes);
        const Case = struct { bytes: []const u8, options: nbt.Options, document: *const nbt.Document };
        var case: Case = .{ .bytes = bytes, .options = options, .document = &document };
        std.debug.print("{s}: {d} B\n", .{ @tagName(format), bytes.len });
        try measure(io, "  scan " ++ @tagName(format), bytes.len, &case, struct {
            fn run(c: *Case) !void {
                std.mem.doNotOptimizeAway(try nbt.scanDocument(c.bytes, c.options));
            }
        }.run);
        try measure(io, "  parse " ++ @tagName(format), bytes.len, &case, struct {
            fn run(c: *Case) !void {
                var parsed = try nbt.parse(allocator, c.bytes, c.options);
                parsed.deinit(allocator);
            }
        }.run);
        try measure(io, "  write " ++ @tagName(format), bytes.len, &case, struct {
            fn run(c: *Case) !void {
                const out = try nbt.serialize(allocator, c.document.*, c.options);
                allocator.free(out);
            }
        }.run);
    }
}

fn ringThroughput(io: std.Io) !void {
    std.debug.print("\n== command/event ring ==\n", .{});
    var ring = try native.Ring.init(allocator, 16 * 1024 * 1024);
    defer ring.deinit(allocator);
    const total = 20_000_000;
    const Producer = struct {
        fn run(r: *native.Ring) void {
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
    const start = nowNs(io);
    const thread = try std.Thread.spawn(.{}, Producer.run, .{&ring});
    var seen: usize = 0;
    while (seen < total) {
        while (ring.next()) |_| seen += 1;
        ring.release();
    }
    thread.join();
    report("64 B records across threads", total, nowNs(io) - start, 0);
}

/// Plays the PHP side: answers each login step and echoes stamped packets.
const Server = struct {
    host: *native.Host,
    /// Any valid key will do, since NetherNet sessions are not encrypted by Bedrock.
    key: @TypeOf(bedwire.crypto.spki.encode(undefined)),
    steps: std.AutoHashMapUnmanaged(u64, u8) = .empty,
    storage: [4][512]u8 = undefined,
    echoed: usize = 0,

    fn drain(self: *Server) !void {
        while (self.host.nextEvent()) |event| switch (event) {
            .packet => |packet| try self.onPacket(packet.session, packet.bytes),
            else => {},
        };
        self.host.releaseEvents();
    }

    fn onPacket(self: *Server, id: u64, bytes: []const u8) !void {
        if (bytes[0] == peer_mod.stamp_id) {
            self.host.send(id, &.{bytes}) catch {};
            self.echoed += 1;
            return;
        }
        const entry = try self.steps.getOrPut(allocator, id);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        defer entry.value_ptr.* += 1;
        switch (entry.value_ptr.*) {
            0 => try self.host.send(id, &.{peer_mod.typed(&self.storage[0], .{ .network_settings = .{
                .compression_threshold = 256,
                .compression_algorithm = .zlib,
                .client_throttle_enabled = false,
                .client_throttle_threshold = 0,
                .client_throttle_scalar = 0,
            } })}),
            1 => {
                try self.host.acceptLogin(id, &self.key);
                try self.host.send(id, &.{ peer_mod.raw(&self.storage[1], protocol.Current.packetId(.play_status).?, "\x00\x00\x00\x00"), peer_mod.typed(&self.storage[2], .{ .resource_packs_info = .{
                    .resource_pack_required = false,
                    .has_addon_packs = false,
                    .has_scripts = false,
                    .force_disable_vibrant_visuals = false,
                    .world_template_id_and_version = .{ .pack_uuid = @splat(0), .pack_version = "" },
                    .resource_packs = .empty,
                } }) });
            },
            2 => try self.host.send(id, &.{peer_mod.raw(&self.storage[3], protocol.Current.packetId(.start_game).?, "start")}),
            else => {},
        }
    }
};

fn startHost(sessions: usize) !*native.Host {
    return native.Host.start(allocator, .{
        .address = .{ .ip4 = .loopback(0) },
        .authentication = false,
        .max_sessions = @intCast(@max(sessions + 8, 16)),
        .packet_rate = 0,
        .max_batch_bytes = 256 * 1024,
        .event_queue_bytes = 64 * 1024 * 1024,
        .max_negotiations = 64,
        .http_workers = 64,
        .login_timeout_ms = 60_000,
    });
}

const Group = struct {
    io: std.Io,
    port: u16,
    count: usize,
    size: usize,
    rate_hz: u32,
    wakeup: nethernet.Wakeup = .{},
    pool: bedwire.BufferPool = undefined,
    peers: std.ArrayList(*Peer) = .empty,
    latencies: std.ArrayList(u64) = .empty,
    sent: usize = 0,
    ready: std.atomic.Value(bool) = .init(false),
    sending: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    failed: ?anyerror = null,

    fn run(self: *Group) void {
        self.runInner() catch |err| {
            self.failed = err;
        };
        self.ready.store(true, .release);
    }

    fn runInner(self: *Group) !void {
        self.pool = try peer_mod.clientPool(allocator);
        for (0..self.count) |_| {
            const peer = try Peer.connect(allocator, self.io, self.port, &self.pool, &self.wakeup);
            try self.peers.append(allocator, peer);
            try peer.login();
            peer.latencies = &self.latencies;
        }
        self.ready.store(true, .release);
        var storage: [2048]u8 = undefined;
        const interval: u64 = std.time.ns_per_s / self.rate_hz;
        var next = nowNs(self.io);
        while (!self.done.load(.acquire)) {
            const token = self.wakeup.prepare();
            if (self.sending.load(.acquire) and nowNs(self.io) >= next) {
                for (self.peers.items) |peer| {
                    peer.send(&.{peer_mod.stamped(&storage, self.io, self.size)}) catch continue;
                    self.sent += 1;
                }
                next += interval;
            }
            for (self.peers.items) |peer| peer.pump();
            const wait = (next -| nowNs(self.io)) / std.time.ns_per_us;
            self.wakeup.wait(self.io, token, .{ .duration = .{ .raw = .fromMicroseconds(@intCast(@max(wait, 100))), .clock = .awake } }) catch {};
        }
    }

    fn deinit(self: *Group) void {
        for (self.peers.items) |peer| peer.destroy();
        self.peers.deinit(allocator);
        self.latencies.deinit(allocator);
        self.pool.deinit();
    }
};

fn threadCpuNs(io: std.Io, tid: u64) u64 {
    if (@import("builtin").os.tag != .linux) return 0;
    var path: [64]u8 = undefined;
    const name = std.fmt.bufPrint(&path, "/proc/self/task/{d}/stat", .{tid}) catch return 0;
    var buffer: [1024]u8 = undefined;
    const len = (std.Io.Dir.cwd().readFile(io, name, &buffer) catch return 0).len;
    const close = std.mem.lastIndexOfScalar(u8, buffer[0..len], ')') orelse return 0;
    var fields = std.mem.tokenizeScalar(u8, buffer[close + 2 .. len], ' ');
    var i: usize = 0;
    var ticks: u64 = 0;
    while (fields.next()) |field| : (i += 1) {
        // utime and stime are fields 14 and 15 of the file, 11 and 12 after the command name.
        if (i == 11 or i == 12) ticks += std.fmt.parseInt(u64, field, 10) catch 0;
        if (i == 12) break;
    }
    return ticks * 10 * std.time.ns_per_ms;
}

fn processCpuNs() u64 {
    const usage = std.posix.getrusage(std.posix.rusage.SELF);
    const user: u64 = @intCast(usage.utime.sec * std.time.ns_per_s + usage.utime.usec * std.time.ns_per_us);
    const system: u64 = @intCast(usage.stime.sec * std.time.ns_per_s + usage.stime.usec * std.time.ns_per_us);
    return user + system;
}

fn rssBytes(io: std.Io) u64 {
    if (@import("builtin").os.tag != .linux) return 0;
    var buffer: [4096]u8 = undefined;
    const len = (std.Io.Dir.cwd().readFile(io, "/proc/self/status", &buffer) catch return 0).len;
    const start = std.mem.indexOf(u8, buffer[0..len], "VmRSS:") orelse return 0;
    var fields = std.mem.tokenizeAny(u8, buffer[start + 6 .. len], " \t\n");
    return (std.fmt.parseInt(u64, fields.next() orelse return 0, 10) catch 0) * 1024;
}

fn percentile(sorted: []const u64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    const index: usize = @intFromFloat(@min(@as(f64, @floatFromInt(sorted.len - 1)), p * @as(f64, @floatFromInt(sorted.len))));
    return @as(f64, @floatFromInt(sorted[index])) / 1000;
}

/// Clients send a stamped packet at `rate_hz`, the host echoes it, and the clients record round trips.
fn transport(io: std.Io, sessions: usize, rate_hz: u32, seconds: u32) !void {
    std.debug.print("\n== NetherNet end to end: {d} sessions, {d} Hz each, 64 B packets, {d} s ==\n", .{ sessions, rate_hz, seconds });
    const rss_before = rssBytes(io);
    const host = try startHost(sessions);
    defer host.destroy();
    var server: Server = .{ .host = host, .key = bedwire.crypto.spki.encode(bedwire.crypto.spki.Ecdsa.KeyPair.generate(io).public_key) };
    defer server.steps.deinit(allocator);

    const groups = @max(1, sessions / 50);
    const clients = try allocator.alloc(Group, groups);
    defer allocator.free(clients);
    const threads = try allocator.alloc(std.Thread, groups);
    defer allocator.free(threads);
    var started: usize = 0;
    defer for (clients[0..started]) |*group| group.deinit();
    defer for (threads[0..started]) |thread| thread.join();
    defer for (clients[0..started]) |*group| group.done.store(true, .release);

    const join_start = nowNs(io);
    for (clients, threads, 0..) |*group, *thread, i| {
        const count = sessions / groups + @intFromBool(i < sessions % groups);
        group.* = .{ .io = io, .port = host.local_address.getPort(), .count = count, .size = 64, .rate_hz = rate_hz };
        thread.* = try std.Thread.spawn(.{}, Group.run, .{group});
        started += 1;
    }
    for (clients) |*group| {
        while (!group.ready.load(.acquire)) {
            host.waitEvents(2);
            try server.drain();
        }
        if (group.failed) |err| return err;
    }
    const join_ms = @as(f64, @floatFromInt(nowNs(io) - join_start)) / 1e6;
    const rss_joined = rssBytes(io);
    std.debug.print("joined in {d:.0} ms ({d:.1} ms per session, sequential per client thread)\n", .{ join_ms, join_ms / @as(f64, @floatFromInt(sessions)) * @as(f64, @floatFromInt(groups)) });

    for (clients) |*group| group.sending.store(true, .release);
    const worker = host.shared.worker_thread.load(.acquire);
    const cpu_start = processCpuNs();
    const worker_start = threadCpuNs(io, worker);
    const start = nowNs(io);
    const end = start + @as(u64, seconds) * std.time.ns_per_s;
    while (nowNs(io) < end) {
        host.waitEvents(5);
        try server.drain();
    }
    const elapsed = nowNs(io) - start;
    for (clients) |*group| group.sending.store(false, .release);
    const worker_ns = threadCpuNs(io, worker) - worker_start;
    const process_ns = processCpuNs() - cpu_start;

    var latencies: std.ArrayList(u64) = .empty;
    defer latencies.deinit(allocator);
    var sent: usize = 0;
    for (clients) |*group| {
        sent += group.sent;
        try latencies.appendSlice(allocator, group.latencies.items);
    }
    std.mem.sort(u64, latencies.items, {}, std.sort.asc(u64));
    const seconds_f = @as(f64, @floatFromInt(elapsed)) / 1e9;
    std.debug.print("sent {d}, echoed {d}, received back {d} ({d:.0} msg/s each way)\n", .{ sent, server.echoed, latencies.items.len, @as(f64, @floatFromInt(server.echoed)) / seconds_f });
    std.debug.print("round trip us: p50 {d:.0}  p95 {d:.0}  p99 {d:.0}  max {d:.0}\n", .{ percentile(latencies.items, 0.5), percentile(latencies.items, 0.95), percentile(latencies.items, 0.99), percentile(latencies.items, 1.0) });
    std.debug.print("worker thread CPU {d:.1}% of one core, whole process (clients included) {d:.1}%\n", .{ 100 * @as(f64, @floatFromInt(worker_ns)) / @as(f64, @floatFromInt(elapsed)), 100 * @as(f64, @floatFromInt(process_ns)) / @as(f64, @floatFromInt(elapsed)) });
    std.debug.print("RSS growth with sessions (both ends in process): {d:.1} MiB, {d:.0} KiB per session pair\n", .{ @as(f64, @floatFromInt(rss_joined -| rss_before)) / 1048576, @as(f64, @floatFromInt(rss_joined -| rss_before)) / 1024 / @as(f64, @floatFromInt(sessions)) });
}

/// Logged-in sessions that send nothing, to show what an idle server costs.
fn idle(io: std.Io, sessions: usize, seconds: u32) !void {
    std.debug.print("\n== idle: {d} logged-in sessions, no traffic, {d} s ==\n", .{ sessions, seconds });
    const host = try startHost(sessions);
    defer host.destroy();
    var server: Server = .{ .host = host, .key = bedwire.crypto.spki.encode(bedwire.crypto.spki.Ecdsa.KeyPair.generate(io).public_key) };
    defer server.steps.deinit(allocator);
    var group: Group = .{ .io = io, .port = host.local_address.getPort(), .count = sessions, .size = 64, .rate_hz = 1 };
    const thread = try std.Thread.spawn(.{}, Group.run, .{&group});
    defer {
        group.done.store(true, .release);
        thread.join();
        group.deinit();
    }
    while (!group.ready.load(.acquire)) {
        host.waitEvents(2);
        try server.drain();
    }
    if (group.failed) |err| return err;
    const worker = host.shared.worker_thread.load(.acquire);
    const worker_start = threadCpuNs(io, worker);
    const start = nowNs(io);
    try io.sleep(.fromSeconds(seconds), .awake);
    const elapsed = nowNs(io) - start;
    std.debug.print("worker thread CPU {d:.2}% of one core\n", .{100 * @as(f64, @floatFromInt(threadCpuNs(io, worker) - worker_start)) / @as(f64, @floatFromInt(elapsed))});
}
