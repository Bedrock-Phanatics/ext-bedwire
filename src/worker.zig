//! The network thread. It owns every NetherNet connection and Bedwire session and never touches Zend.
const std = @import("std");
const bedwire = @import("bedwire");
const nethernet = @import("nethernet");

const host_mod = @import("host.zig");

const Config = host_mod.Config;
const Shared = host_mod.Shared;
const Statistics = host_mod.Statistics;
const Event = host_mod.Event;
const Command = host_mod.Command;
const Reason = host_mod.Reason;
const Profile = bedwire.protocol.Current;
const Authority = nethernet.identity_issuer.Authority;

const Phase = enum { free, open, draining };

const Slot = struct {
    generation: u32 = 0,
    phase: Phase = .free,
    /// Position in `Worker.active`.
    position: u32 = 0,
    connection: *nethernet.Connection = undefined,
    session: bedwire.Session = undefined,
    reason: Reason = .remote,
    logged_in: bool = false,
    opened_ms: u64 = 0,
    drain_deadline_ms: u64 = 0,
    tokens: u32 = 0,
    refilled_ms: u64 = 0,
};

/// Bedwire's view of the JWKS that nethernet's authority last fetched.
const Keys = struct {
    source: []u8 = &.{},
    set: ?bedwire.auth.KeySet = null,

    fn deinit(self: *Keys, allocator: std.mem.Allocator) void {
        if (self.set) |*set| set.deinit();
        allocator.free(self.source);
        self.* = .{};
    }
};

/// LAN discovery and signaling, which vanilla clients use to find servers on the local network.
const Lan = struct {
    discovery: *nethernet.Discovery,
    listener: *nethernet.LanListener,
    version: u32 = 0,
    players: u32 = std.math.maxInt(u32),

    fn open(allocator: std.mem.Allocator, io: std.Io, config: *const Config, connection: nethernet.ConnectionOptions, wakeup: *nethernet.Wakeup) !Lan {
        const address: std.Io.net.IpAddress = switch (config.address) {
            .ip4 => .{ .ip4 = .unspecified(config.lan_port) },
            .ip6 => .{ .ip6 = .unspecified(config.lan_port) },
        };
        const discovery = try nethernet.Discovery.listen(allocator, io, address, .{});
        errdefer discovery.destroy();
        const listener = try nethernet.LanListener.listen(allocator, discovery, .{
            .connection = connection,
            .maximum_negotiations = config.max_negotiations,
            .wakeup = wakeup,
        });
        return .{ .discovery = discovery, .listener = listener };
    }

    fn close(self: *Lan) void {
        self.listener.destroy();
        self.discovery.destroy();
    }
};

/// Decides which client identities signaling accepts: those Minecraft's keys signed, and self-signed ones
/// whose key is configured as trusted, such as a proxy's.
const Trust = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    authority: ?*Authority,
    keys: []const []const u8,

    /// Without authentication every client is accepted, and the identity digest still lets PHP recognise proxies.
    fn verifier(self: *Trust) ?nethernet.sdp_identity.Verifier {
        if (self.authority == null) return null;
        return .{ .context = self, .verify = verify };
    }

    fn verify(context: ?*anyopaque, token: []const u8) anyerror!?nethernet.sdp_identity.Key {
        const self: *Trust = @ptrCast(@alignCast(context.?));
        // Listed keys are checked first, since it is cheap and never waits on fetching Minecraft's keys.
        if (self.keys.len != 0) {
            const key = try nethernet.identity.claimPublicKey(self.allocator, token, std.Io.Clock.real.now(self.io).toSeconds(), .client);
            const der = bedwire.crypto.spki.encode(key);
            for (self.keys) |trusted| if (std.mem.eql(u8, trusted, &der)) return key;
        }
        const authority = self.authority.?;
        return authority.verifier().verify(authority, token);
    }
};

pub const Worker = struct {
    /// Event space held back so every live session's disconnect is always delivered.
    pub const obligation_bytes = 32;
    /// One disconnect may wrap the ring and pad up to 16 bytes, which a lone session's 8 bytes of slack can't cover.
    const obligation_wrap_bytes = 16;
    const commands_per_turn = 4096;
    const messages_per_turn = 64;
    const drain_poll_ms = 10;

    allocator: std.mem.Allocator,
    io: std.Io,
    shared: *Shared,
    config: *const Config,
    listener: *nethernet.EndpointListener,
    lan: ?Lan,
    trust: *Trust,
    authority: ?*Authority,
    keys: Keys = .{},
    ice_servers: [][*:0]const u8,
    pool: bedwire.BufferPool,
    limits: bedwire.Limits,
    slots: []Slot,
    free: []u32,
    free_len: usize,
    active: []u32,
    active_len: usize = 0,
    draining: usize = 0,
    group: [host_mod.max_packets_per_batch][]const u8 = undefined,

    stats: Statistics = .{},
    closed_bytes_received: u64 = 0,
    closed_bytes_sent: u64 = 0,
    next_tick_ms: u64 = 0,
    shutdown_deadline: ?u64 = null,
    stalled: bool = false,
    dirty: bool = false,

    pub fn create(allocator: std.mem.Allocator, io: std.Io, shared: *Shared, config: *const Config) !*Worker {
        const self = try allocator.create(Worker);
        errdefer allocator.destroy(self);

        var limits: bedwire.Limits = .{
            .max_frame_bytes = host_mod.max_frame_bytes,
            .max_batch_bytes = config.max_batch_bytes,
            .max_packet_bytes = config.max_batch_bytes,
        };
        limits.max_connection_request_bytes = @min(limits.max_connection_request_bytes, config.max_batch_bytes);
        // Sessions are served one at a time, so one receive and one send buffer cover all of them.
        var pool = try bedwire.BufferPool.init(allocator, limits, .{ .rx_slots = 1, .tx_slots = 1 });
        errdefer pool.deinit();

        const slots = try allocator.alloc(Slot, config.max_sessions);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        const free = try allocator.alloc(u32, config.max_sessions);
        errdefer allocator.free(free);
        for (free, 0..) |*index, i| index.* = @intCast(config.max_sessions - 1 - i);
        const active = try allocator.alloc(u32, config.max_sessions);
        errdefer allocator.free(active);

        const authority: ?*Authority = if (config.authentication) blk: {
            const value = try allocator.create(Authority);
            value.* = .init(allocator, io);
            break :blk value;
        } else null;
        errdefer if (authority) |value| {
            value.deinit();
            allocator.destroy(value);
        };

        const trust = try allocator.create(Trust);
        errdefer allocator.destroy(trust);
        trust.* = .{ .allocator = allocator, .io = io, .authority = authority, .keys = config.trusted_identity_keys };
        const ice_servers = try allocator.alloc([*:0]const u8, config.ice_servers.len);
        errdefer allocator.free(ice_servers);
        for (ice_servers, config.ice_servers) |*pointer, server| pointer.* = server.ptr;

        // One identity for HTTP and LAN signaling, so a player confirms the server once.
        const identity_key = if (config.identity_file) |path| try nethernet.identity_file.loadOrCreate(io, allocator, path) else nethernet.IdentityKeyPair.generate(io);
        const connection: nethernet.ConnectionOptions = .{
            .server_identity_key = identity_key,
            .allow_anonymous = authority == null,
            .verify_client = trust.verifier(),
            .maximum_message_size = host_mod.max_frame_bytes,
            .native = .{
                .queue_bytes = config.receive_queue_bytes,
                .maximum_buffered_send = config.send_buffer_bytes,
                .port_range_begin = config.port_range_begin,
                .port_range_end = config.port_range_end,
                .enable_ice_udp_mux = config.udp_mux,
                .ice_servers = ice_servers,
                .bind_address = config.bind_address,
            },
        };
        const listener = try nethernet.EndpointListener.listen(allocator, io, config.address, .{
            .connection = connection,
            .maximum_negotiations = config.max_negotiations,
            .maximum_http_workers = config.http_workers,
            .maximum_pending_accepts = config.max_negotiations,
            .status_provider = .{ .context = shared, .get = status },
            .wakeup = &shared.wakeup,
        });
        errdefer listener.destroy();
        var lan: ?Lan = if (config.lan_port != 0) try Lan.open(allocator, io, config, connection, &shared.wakeup) else null;
        errdefer if (lan) |*value| value.close();

        self.* = .{
            .allocator = allocator,
            .io = io,
            .shared = shared,
            .config = config,
            .listener = listener,
            .lan = lan,
            .trust = trust,
            .ice_servers = ice_servers,
            .authority = authority,
            .pool = pool,
            .limits = limits,
            .slots = slots,
            .free = free,
            .free_len = free.len,
            .active = active,
        };
        self.next_tick_ms = self.clock() + config.stats_interval_ms;
        self.advertise();
        return self;
    }

    pub fn destroy(self: *Worker) void {
        for (self.active[0..self.active_len]) |index| {
            const slot = &self.slots[index];
            slot.session.deinit();
            slot.connection.destroy();
        }
        self.listener.destroy();
        if (self.lan) |*lan| lan.close();
        self.allocator.destroy(self.trust);
        self.allocator.free(self.ice_servers);
        self.keys.deinit(self.allocator);
        if (self.authority) |authority| {
            authority.deinit();
            self.allocator.destroy(authority);
        }
        self.allocator.free(self.active);
        self.allocator.free(self.free);
        self.allocator.free(self.slots);
        self.pool.deinit();
        self.allocator.destroy(self);
    }

    pub fn run(self: *Worker) void {
        self.shared.worker_thread.store(std.Thread.getCurrentId(), .release);
        defer self.finish();
        while (true) {
            const token = self.shared.wakeup.prepare();
            var busy = self.processCommands();
            self.acceptConnections();
            busy = self.pumpConnections() or busy;

            const now = self.clock();
            if (now >= self.next_tick_ms) {
                self.tick(now);
                self.next_tick_ms = now + self.config.stats_interval_ms;
            }
            self.publishStats();
            self.publishEvents();

            if (self.shutdown_deadline == null and self.shared.stop_requested.load(.seq_cst)) self.beginShutdown(now);
            if (self.shutdown_deadline) |end| {
                if (self.active_len == 0 or now >= end) return;
            }
            if (busy and !self.stalled) continue;

            self.shared.wakeup.wait(self.io, token, self.waitUntil(now)) catch {};
        }
    }

    fn waitUntil(self: *Worker, now: u64) std.Io.Timeout {
        var until = self.next_tick_ms;
        if (self.draining != 0) until = @min(until, now + drain_poll_ms);
        if (self.shutdown_deadline) |end| until = @min(until, end);
        var earliest = std.Io.Clock.awake.now(self.io).addDuration(.fromMilliseconds(@intCast(until -| now)));
        for (self.active[0..self.active_len]) |index| earlier(&earliest, self.slots[index].connection.waitDeadline());
        if (self.lan) |lan| {
            earlier(&earliest, lan.discovery.tickDeadline());
            for (lan.listener.pending) |pending| if (pending) |connection| earlier(&earliest, connection.waitDeadline());
        }
        return .{ .deadline = .{ .raw = earliest, .clock = .awake } };
    }

    fn earlier(earliest: *std.Io.Timestamp, timeout: std.Io.Timeout) void {
        switch (timeout) {
            .deadline => |at| if (at.raw.nanoseconds < earliest.nanoseconds) {
                earliest.* = at.raw;
            },
            else => {},
        }
    }

    fn finish(self: *Worker) void {
        while (self.active_len != 0) self.release(&self.slots[self.active[self.active_len - 1]]);
        self.sumTraffic();
        self.publishStats();
        self.publishEvents();
        self.shared.exited.store(true, .seq_cst);
        self.shared.notifyConsumer(self.io);
    }

    fn beginShutdown(self: *Worker, now: u64) void {
        for (self.active[0..self.active_len]) |index| self.close(&self.slots[index], .shutdown, now);
        self.shutdown_deadline = now + self.shared.stop_timeout_ms.load(.monotonic);
    }

    fn clock(self: *Worker) u64 {
        const ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        return @intCast(@divTrunc(ns, std.time.ns_per_ms));
    }

    fn status(context: ?*anyopaque) anyerror!nethernet.EndpointServerStatus {
        const shared: *Shared = @ptrCast(@alignCast(context.?));
        const Copy = struct {
            threadlocal var name: host_mod.Status.Text = .{};
            threadlocal var level: host_mod.Status.Text = .{};
        };
        const current = &shared.status;
        // Copied per HTTP thread so PHP can change the status while a response is being written.
        current.mutex.lockUncancelable(current.io);
        defer current.mutex.unlock(current.io);
        Copy.name = current.name;
        Copy.level = current.level;
        return .{
            .name = Copy.name.slice(),
            .protocol = Profile.protocol_number,
            .version = Profile.minecraft_version,
            .level = Copy.level.slice(),
            .players = @intCast(@min(shared.stats[0].load(.monotonic), current.max_players)),
            .max_players = current.max_players,
            .game_type = current.game_type,
        };
    }

    fn reserveObligations(self: *const Worker, extra: usize) usize {
        return (self.active_len + extra) * obligation_bytes + obligation_wrap_bytes;
    }

    fn emit(self: *Worker, event: Event, len: usize) ?[]u8 {
        return self.shared.events.reserve(@backingInt(event), len, self.reserveObligations(0));
    }

    fn commitEvent(self: *Worker) void {
        self.shared.events.commit();
        self.dirty = true;
    }

    fn publishEvents(self: *Worker) void {
        if (!self.dirty) return;
        self.dirty = false;
        self.shared.events.publish();
        self.shared.notifyConsumer(self.io);
    }

    /// Counters are published every turn, while live byte totals are summed only on the tick.
    fn publishStats(self: *Worker) void {
        self.stats.sessions = self.active_len;
        self.shared.storeStats(self.stats);
    }

    fn sumTraffic(self: *Worker) void {
        var received = self.closed_bytes_received;
        var sent = self.closed_bytes_sent;
        for (self.active[0..self.active_len]) |index| {
            const connection = self.slots[index].connection;
            received += connection.received_bytes;
            sent += connection.sent_bytes;
        }
        self.stats.bytes_received = received;
        self.stats.bytes_sent = sent;
    }

    fn sessionId(self: *const Worker, slot: *const Slot) u64 {
        return host_mod.sessionId(self.indexOf(slot), slot.generation);
    }

    fn indexOf(self: *const Worker, slot: *const Slot) u32 {
        return @intCast((@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot));
    }

    fn resolve(self: *Worker, id: u64) ?*Slot {
        const parts = host_mod.sessionParts(id) orelse return null;
        if (parts.index >= self.slots.len) return null;
        const slot = &self.slots[parts.index];
        if (slot.phase != .open or slot.generation != parts.generation) return null;
        return slot;
    }

    fn acceptConnections(self: *Worker) void {
        while (self.listener.pollAccept() catch null) |connection| self.open(connection);
        if (self.lan) |lan| while (lan.listener.pollAccept() catch null) |connection| self.open(connection);
    }

    /// Keeps the LAN advertisement in step with the status PHP sets and the live player count.
    fn advertise(self: *Worker) void {
        const lan = &(self.lan orelse return);
        const current = &self.shared.status;
        current.mutex.lockUncancelable(self.io);
        defer current.mutex.unlock(self.io);
        const players: u32 = @intCast(@min(self.active_len, current.max_players));
        if (lan.version == current.version and lan.players == players) return;
        lan.discovery.setServerData(.{
            .server_name = current.name.slice(),
            .protocol = @intCast(Profile.protocol_number),
            .version = Profile.minecraft_version,
            .level_name = current.level.slice(),
            .game_type = current.game_type,
            .player_count = @intCast(players),
            .max_player_count = @intCast(@min(current.max_players, std.math.maxInt(i32))),
            .accepts_online_auth = self.authority != null,
            .accepts_self_signed_auth = self.authority == null,
        }) catch return;
        lan.version = current.version;
        lan.players = players;
    }

    fn open(self: *Worker, connection: *nethernet.Connection) void {
        var address_buffer: [256]u8 = undefined;
        var unused: [256]u8 = undefined;
        const address = if (connection.selectedIceAddresses(&unused, &address_buffer) catch null) |pair| pair.remote else "";
        var digest: [32]u8 = undefined;
        const identity: []const u8 = if (connection.public_key) |key| blk: {
            std.crypto.hash.sha2.Sha256.hash(&bedwire.crypto.spki.encode(key), &digest, .{});
            break :blk &digest;
        } else &.{};
        const network_id = connection.remote_id[0..@min(connection.remote_id.len, 256)];

        const len = 12 + address.len + identity.len + network_id.len;
        const refused = self.shutdown_deadline != null or self.free_len == 0;
        const bytes = if (refused) null else self.shared.events.reserve(@backingInt(Event.connect), len, self.reserveObligations(1));
        const record = bytes orelse {
            self.stats.connections_refused += 1;
            connection.destroy();
            return;
        };
        const session = bedwire.Session.init(.server, .{
            .pool = &self.pool,
            .policy = .{ .encryption = .disabled, .batch_header = false },
        }) catch {
            self.stats.connections_refused += 1;
            connection.destroy();
            return;
        };
        const index = self.free[self.free_len - 1];
        self.free_len -= 1;
        const slot = &self.slots[index];
        const generation = if (slot.generation +% 1 == 0) 1 else slot.generation +% 1;
        const now = self.clock();
        slot.* = .{
            .generation = generation,
            .phase = .open,
            .position = @intCast(self.active_len),
            .connection = connection,
            .session = session,
            .opened_ms = now,
            .tokens = self.config.packet_rate,
            .refilled_ms = now,
        };
        self.active[self.active_len] = index;
        self.active_len += 1;
        connection.peer.subscribe(&self.shared.wakeup);

        std.mem.writeInt(u64, record[0..8], self.sessionId(slot), .little);
        std.mem.writeInt(u16, record[8..10], @intCast(address.len), .little);
        record[10] = @intCast(identity.len);
        record[11] = @intFromBool(connection.identity_issuer_verified);
        @memcpy(record[12..][0..address.len], address);
        @memcpy(record[12 + address.len ..][0..identity.len], identity);
        @memcpy(record[12 + address.len + identity.len ..], network_id);
        self.commitEvent();
        self.shared.live[index].store(slot.generation, .release);
    }

    /// Ends a session; the disconnect event uses space reserved for it, so it is never lost.
    fn release(self: *Worker, slot: *Slot) void {
        const index = self.indexOf(slot);
        if (self.shared.events.reserve(@backingInt(Event.disconnect), 9, 0)) |out| {
            std.mem.writeInt(u64, out[0..8], self.sessionId(slot), .little);
            out[8] = @backingInt(slot.reason);
            self.commitEvent();
        }
        self.shared.live[index].store(0, .release);
        if (slot.phase == .draining) self.draining -= 1;

        const callback = slot.connection.callbackStats();
        self.stats.receive_pauses += callback.receive_pauses;
        self.closed_bytes_received += slot.connection.received_bytes;
        self.closed_bytes_sent += slot.connection.sent_bytes;
        slot.session.deinit();
        slot.connection.destroy();

        const last = self.active[self.active_len - 1];
        self.active[slot.position] = last;
        self.slots[last].position = slot.position;
        self.active_len -= 1;
        slot.phase = .free;
        self.free[self.free_len] = index;
        self.free_len += 1;
    }

    /// Stops accepting commands for the session and lets queued data drain before closing.
    fn close(self: *Worker, slot: *Slot, reason: Reason, now: u64) void {
        if (slot.phase != .open) return;
        slot.reason = reason;
        switch (reason) {
            .protocol => self.stats.protocol_disconnects += 1,
            .overload => self.stats.overload_disconnects += 1,
            .authentication => self.stats.authentication_failures += 1,
            .timeout => self.stats.timeouts += 1,
            else => {},
        }
        slot.session.beginClose();
        slot.phase = .draining;
        slot.drain_deadline_ms = now + slot.connection.options.graceful_shutdown_timeout_ms;
        self.draining += 1;
        self.shared.live[self.indexOf(slot)].store(0, .release);
    }

    fn fail(self: *Worker, slot: *Slot, reason: Reason) void {
        self.close(slot, reason, self.clock());
        slot.connection.close();
    }

    fn pumpConnections(self: *Worker) bool {
        var busy = false;
        var i: usize = 0;
        while (i < self.active_len) {
            const slot = &self.slots[self.active[i]];
            switch (self.pump(slot)) {
                .idle => i += 1,
                .busy => {
                    busy = true;
                    i += 1;
                },
                .released => {},
            }
        }
        return busy;
    }

    fn pump(self: *Worker, slot: *Slot) enum { idle, busy, released } {
        for (0..messages_per_turn) |_| {
            if (slot.phase == .open and self.shared.events.available() < self.reserveObligations(0) + self.config.max_batch_bytes) {
                // Leave messages queued so NetherNet pauses the sender until PHP catches up.
                self.stats.event_stalls += 1;
                self.stalled = true;
                self.shared.wants_events_space.store(true, .seq_cst);
                if (self.shared.events.available() < self.reserveObligations(0) + self.config.max_batch_bytes) return .idle;
                self.shared.wants_events_space.store(false, .seq_cst);
                self.stalled = false;
            }
            const event = slot.connection.poll() catch {
                self.release(slot);
                return .released;
            } orelse return .idle;
            const message = switch (event) {
                .signal => continue,
                .message => |message| message,
            };
            if (slot.phase != .open) continue;
            if (message.reliability != .reliable) {
                self.deliverUnreliable(slot, message.data);
                continue;
            }
            self.ingest(slot, message.data) catch |err| self.fail(slot, switch (err) {
                error.EventQueueFull, error.PacketRate => .overload,
                error.Unauthenticated => .authentication,
                else => .protocol,
            });
        }
        return .busy;
    }

    /// Unreliable messages carry no ordering, so they bypass the session and reach PHP as they arrived.
    fn deliverUnreliable(self: *Worker, slot: *Slot, payload: []const u8) void {
        if (!self.config.unreliable_events or payload.len == 0 or !self.takeToken(slot)) {
            self.stats.unreliable_dropped += 1;
            return;
        }
        const bytes = self.emit(.unreliable, 8 + payload.len) orelse {
            self.stats.unreliable_dropped += 1;
            return;
        };
        std.mem.writeInt(u64, bytes[0..8], self.sessionId(slot), .little);
        @memcpy(bytes[8..], payload);
        self.commitEvent();
    }

    /// Every packet is copied into the event queue before the connection is polled again, so the message can be borrowed.
    fn ingest(self: *Worker, slot: *Slot, payload: []const u8) !void {
        var packets = try slot.session.ingestBorrowed(payload);
        defer packets.deinit();
        const id = self.sessionId(slot);

        while (packets.next()) |packet| {
            if (!self.takeToken(slot)) return error.PacketRate;
            if (packet.kind == .login and self.authority != null) try self.authenticate(slot, packet);
            const bytes = self.emit(.packet, 8 + packet.bytes.len) orelse return error.EventQueueFull;
            std.mem.writeInt(u64, bytes[0..8], id, .little);
            @memcpy(bytes[8..], packet.bytes);
            self.commitEvent();
            self.stats.packets_received += 1;
        }
        _ = slot.session.settle();
    }

    /// Session ID, name length, UUID and the client key's DER, ahead of the name and XUID.
    pub const login_header = 46 + @sizeOf(@TypeOf(bedwire.crypto.spki.encode(undefined)));

    /// Verifies Microsoft-signed logins here and reports them before the Login packet. Others, such as offline
    /// or proxy logins, are left to PHP, and the session cannot pass the login stage until it calls acceptLogin.
    fn authenticate(self: *Worker, slot: *Slot, packet: bedwire.Packet) !void {
        var identity = self.verifyLogin(slot, packet) catch {
            self.stats.login_fallbacks += 1;
            return;
        };
        defer identity.deinit();
        try slot.session.installVerifiedClientKey(identity.public_key);
        self.stats.native_logins += 1;

        const name = identity.display_name[0..@min(identity.display_name.len, std.math.maxInt(u16))];
        const key = bedwire.crypto.spki.encode(identity.public_key);
        const bytes = self.emit(.login, login_header + name.len + identity.xuid.len) orelse return error.EventQueueFull;
        std.mem.writeInt(u64, bytes[0..8], self.sessionId(slot), .little);
        std.mem.writeInt(u16, bytes[8..10], @intCast(name.len), .little);
        @memcpy(bytes[10..46], identity.uuid);
        @memcpy(bytes[46..login_header], &key);
        @memcpy(bytes[login_header..][0..name.len], name);
        @memcpy(bytes[login_header + name.len ..], identity.xuid);
        self.commitEvent();
        slot.logged_in = true;
    }

    fn verifyLogin(self: *Worker, slot: *Slot, packet: bedwire.Packet) !bedwire.Identity {
        const keys = try self.currentKeys();
        const decoded = try slot.session.decodePacket(packet);
        if (decoded.value != .typed or decoded.value.typed != .login) return error.InvalidProfile;
        const request = try bedwire.auth.decodeConnectionRequest(decoded.value.typed.login.connection_request, self.limits);
        var envelope = try bedwire.auth.parseChainEnvelope(self.allocator, request.chain_data, self.limits);
        defer envelope.deinit();
        if (envelope.authentication_type != 0) return error.Unauthenticated;
        const token = envelope.token orelse return error.Unauthenticated;
        const now = std.Io.Clock.real.now(self.io).toSeconds();
        var identity = try bedwire.auth.verifyOidc(self.allocator, token, request.client_data, .{ .now = now, .keys = keys }, self.limits);
        errdefer identity.deinit();
        if (identity.uuid.len != 36) return error.Unauthenticated;
        return identity;
    }

    /// Parses the authority's key snapshot again only when its contents changed.
    fn currentKeys(self: *Worker) !*const bedwire.auth.KeySet {
        const authority = self.authority.?;
        authority.mutex.lockUncancelable(self.io);
        defer authority.mutex.unlock(self.io);
        const snapshot = authority.keys orelse return error.Unauthenticated;
        if (self.keys.set == null or !std.mem.eql(u8, self.keys.source, snapshot.source)) {
            self.keys.deinit(self.allocator);
            const source = self.allocator.dupe(u8, snapshot.source) catch return error.Unauthenticated;
            self.keys.set = bedwire.auth.KeySet.parse(self.allocator, source, self.limits) catch {
                self.allocator.free(source);
                return error.Unauthenticated;
            };
            self.keys.source = source;
        }
        return &self.keys.set.?;
    }

    fn takeToken(self: *Worker, slot: *Slot) bool {
        const rate = self.config.packet_rate;
        if (rate == 0) return true;
        if (slot.tokens == 0) {
            const now_ms = self.clock();
            const refill = @min(@as(u64, rate), (now_ms -| slot.refilled_ms) * rate / 1000);
            if (refill == 0) return false;
            slot.tokens = @intCast(refill);
            slot.refilled_ms = now_ms;
        }
        slot.tokens -= 1;
        return true;
    }

    fn tick(self: *Worker, now: u64) void {
        var i: usize = 0;
        while (i < self.active_len) : (i += 1) {
            const slot = &self.slots[self.active[i]];
            if (slot.phase == .open and !slot.logged_in and now -| slot.opened_ms >= self.config.login_timeout_ms) {
                self.fail(slot, .timeout);
            }
        }
        self.sumTraffic();
        self.advertise();
        self.drainClosing(now);
    }

    fn drainClosing(self: *Worker, now: u64) void {
        if (self.draining == 0) return;
        var i: usize = 0;
        while (i < self.active_len) {
            const slot = &self.slots[self.active[i]];
            const done = slot.phase == .draining and
                (now >= slot.drain_deadline_ms or (slot.connection.diagnostics().bufferedOutgoingBytes() == 0 and
                    slot.connection.unackedAmount() == 0));
            if (done) self.release(slot) else i += 1;
        }
    }

    fn processCommands(self: *Worker) bool {
        const ring = &self.shared.commands;
        defer ring.release();
        if (self.draining != 0) self.drainClosing(self.clock());
        for (0..commands_per_turn) |_| {
            const record = ring.next() orelse return false;
            self.dispatch(@fromBackingInt(@intCast(record.tag)), record.bytes);
        }
        return !ring.isEmpty();
    }

    fn dispatch(self: *Worker, command: Command, bytes: []u8) void {
        const slot = self.resolve(std.mem.readInt(u64, bytes[0..8], .little)) orelse return;
        switch (command) {
            .send => self.handleSend(slot, bytes),
            .disconnect => self.close(slot, .server, self.clock()),
            .accept_login => {
                const key = bedwire.crypto.spki.decode(bytes[8..]) catch return self.fail(slot, .authentication);
                slot.session.installVerifiedClientKey(key) catch return self.fail(slot, .protocol);
                slot.logged_in = true;
            },
            .send_unreliable => slot.connection.send(bytes[8..], .unreliable) catch {
                self.stats.unreliable_dropped += 1;
            },
        }
    }

    fn handleSend(self: *Worker, slot: *Slot, bytes: []u8) void {
        var packets: [host_mod.max_packets_per_batch][]const u8 = undefined;
        var count: usize = 0;
        var total: usize = 0;
        _ = self.gather(bytes, &packets, &count, &total);

        // Merge sends already queued for this session into one frame.
        const ring = &self.shared.commands;
        const id = self.sessionId(slot);
        while (true) {
            const mark = ring.position();
            const next = ring.next() orelse break;
            const merged = next.tag == @backingInt(Command.send) and
                std.mem.readInt(u64, next.bytes[0..8], .little) == id and
                self.gather(next.bytes, &packets, &count, &total);
            if (!merged) {
                ring.rewind(mark);
                break;
            }
        }
        self.sendPackets(slot, packets[0..count]) catch {};
    }

    fn gather(self: *const Worker, bytes: []const u8, packets: *[host_mod.max_packets_per_batch][]const u8, count: *usize, total: *usize) bool {
        var added: usize = 0;
        var offset: usize = 8;
        while (offset < bytes.len) : (added += 1) offset += 4 + std.mem.readInt(u32, bytes[offset..][0..4], .little);
        const size = bytes.len - 8;
        const limit = @min(self.config.max_batch_bytes, host_mod.max_frame_bytes - 64);
        if (count.* != 0 and (count.* + added > packets.len or total.* + size > limit)) return false;
        offset = 8;
        while (offset < bytes.len) : (count.* += 1) {
            const len = std.mem.readInt(u32, bytes[offset..][0..4], .little);
            packets[count.*] = bytes[offset + 4 ..][0..len];
            offset += 4 + len;
        }
        total.* += size;
        return true;
    }

    fn sendPackets(self: *Worker, slot: *Slot, packets: []const []const u8) !void {
        var len: usize = 0;
        for (packets) |packet| {
            const header = bedwire.protocol.packet.decode(packet, .{ .max_packet_bytes = packet.len }) catch {
                self.stats.packets_rejected += 1;
                continue;
            };
            const kind = Profile.packetKind(header.header.packet_id);
            if (!slot.session.state.permits(Profile.features, .server, kind)) {
                self.stats.packets_rejected += 1;
                continue;
            }
            self.group[len] = packet;
            len += 1;
            const boundary = kind == .network_settings or kind == .start_game or slot.session.state.singlePacketBatch();
            if (!boundary) continue;

            try self.flushGroup(slot, len);
            len = 0;
            if (kind == .network_settings) {
                slot.session.negotiateFromSettings(.{ .kind = kind, .id = header.header.packet_id, .bytes = packet }) catch |err| {
                    self.fail(slot, .protocol);
                    return err;
                };
            } else if (kind == .start_game) {
                _ = slot.session.settle();
            }
        }
        if (len != 0) try self.flushGroup(slot, len);
    }

    fn flushGroup(self: *Worker, slot: *Slot, len: usize) !void {
        const frame = slot.session.encode(self.group[0..len]) catch |err| {
            // The login is not accepted yet, so only these packets are refused.
            if (err == error.Unauthenticated) {
                self.stats.packets_rejected += len;
                return;
            }
            self.fail(slot, .protocol);
            return err;
        };
        defer frame.release();
        self.stats.batches_sent += 1;
        slot.connection.send(frame.bytes, .reliable) catch |err| {
            // A peer that stops reading until its send buffer fills is disconnected rather than buffered without bound.
            self.fail(slot, if (err == error.Backpressure) .overload else .remote);
            return err;
        };
    }
};
