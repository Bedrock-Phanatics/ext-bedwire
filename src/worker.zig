const std = @import("std");
const bedwire = @import("bedwire");
const raknet = @import("raknet");

const host_mod = @import("host.zig");
const address_mod = @import("address.zig");

const Config = host_mod.Config;
const Shared = host_mod.Shared;
const Statistics = host_mod.Statistics;
const Event = host_mod.Event;
const Command = host_mod.Command;
const Reason = host_mod.Reason;
const Profile = bedwire.protocol.Current;
const Callbacks = @typeInfo(@TypeOf(raknet.Server.poll)).@"fn".param_types[2].?;

const Pending = struct { handle: raknet.SendHandle, id: u64 };

const Slot = struct {
    generation: u32 = 0,
    live: bool = false,
    closing: bool = false,
    handle: raknet.SessionHandle = undefined,
    session: bedwire.Session = undefined,
    reason: Reason = .remote,
    tokens: u32 = 0,
    refilled_ms: u64 = 0,
    receipts: std.ArrayList(Pending) = .empty,
};

const Outcome = enum { done, stall };

pub const Worker = struct {
    /// Event space held back for every session disconnect and tracked receipt.
    pub const obligation_bytes = 48;
    const commands_per_turn = 4096;

    allocator: std.mem.Allocator,
    io: std.Io,
    shared: *Shared,
    config: *const Config,
    listener: *raknet.Server,
    pool: bedwire.BufferPool,
    policy: bedwire.SessionPolicy,
    slots: []Slot,
    free: []u32,
    free_len: usize,
    receipt_slots: std.ArrayList(u32),
    blocked: std.AutoHashMapUnmanaged(address_mod.Key, u64) = .empty,
    raw_prefixes: [Config.max_raw_prefixes][Config.max_raw_prefix_len]u8 = undefined,
    raw_lens: [Config.max_raw_prefixes]u8 = @splat(0),
    raw_tokens: u32 = 0,
    raw_refilled_ms: u64 = 0,
    group: [host_mod.max_packets_per_batch][]const u8 = undefined,

    active: usize = 0,
    receipts: usize = 0,
    stats: Statistics = .{},
    next_ping_ms: u64 = 0,
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
        var pool = try bedwire.BufferPool.init(allocator, limits, .{ .rx_slots = 1, .tx_slots = 1 });
        errdefer pool.deinit();

        const slots = try allocator.alloc(Slot, config.max_sessions);
        errdefer allocator.free(slots);
        @memset(slots, .{});
        const free = try allocator.alloc(u32, config.max_sessions);
        errdefer allocator.free(free);
        for (free, 0..) |*index, i| index.* = @intCast(config.max_sessions - 1 - i);

        var receipt_slots = try std.ArrayList(u32).initCapacity(allocator, config.max_sessions);
        errdefer receipt_slots.deinit(allocator);

        var raknet_config: raknet.Config = .{};
        raknet_config.listener.maximum_connections = config.max_sessions;
        raknet_config.protocol.maximum_split_bytes = host_mod.max_frame_bytes;
        const listener = try raknet.Server.listen(allocator, io, config.address, .{
            .config = raknet_config,
            .server_guid = config.guid,
            .advertisement = config.advertisement,
            .offline_rate_per_second = config.handshake_rate,
            .offline_burst = config.handshake_rate *| 2,
            .global_offline_rate_per_second = @max(20_000, config.handshake_rate),
            .global_offline_burst = @max(40_000, config.handshake_rate *| 2),
        });
        errdefer listener.destroy();

        self.* = .{
            .allocator = allocator,
            .io = io,
            .shared = shared,
            .config = config,
            .listener = listener,
            .pool = pool,
            .policy = .{ .encryption = if (config.encryption) .required else .optional },
            .slots = slots,
            .free = free,
            .free_len = free.len,
            .receipt_slots = receipt_slots,
        };
        try self.blocked.ensureTotalCapacity(allocator, config.max_blocked);
        for (config.raw_prefixes, 0..) |prefix, i| {
            @memcpy(self.raw_prefixes[i][0..prefix.len], prefix);
            self.raw_lens[i] = @intCast(prefix.len);
        }
        const now = self.clock();
        self.raw_tokens = config.raw_rate;
        self.raw_refilled_ms = now;
        self.next_ping_ms = now + config.ping_interval_ms;
        return self;
    }

    pub fn destroy(self: *Worker) void {
        for (self.slots) |*slot| {
            if (slot.live) slot.session.deinit();
            slot.receipts.deinit(self.allocator);
        }
        self.listener.destroy();
        self.blocked.deinit(self.allocator);
        self.receipt_slots.deinit(self.allocator);
        self.allocator.free(self.free);
        self.allocator.free(self.slots);
        self.pool.deinit();
        self.allocator.destroy(self);
    }

    pub fn run(self: *Worker) void {
        self.shared.worker_thread.store(std.Thread.getCurrentId(), .release);
        defer self.finish();
        while (true) {
            const more = self.processCommands();
            const now = self.clock();

            if (self.shutdown_deadline == null and self.shared.stop_requested.load(.seq_cst)) {
                if (more and !self.stalled) continue;
                self.beginShutdown(now);
            }
            if (self.shutdown_deadline) |deadline| {
                if (self.listener.sessions.count() == 0 or now >= deadline) return;
            }

            var wait_ms: u64 = if (more and !self.stalled) 0 else self.next_ping_ms -| now;
            if (self.shutdown_deadline) |deadline| wait_ms = @min(wait_ms, deadline -| now);
            if (wait_ms != 0) {
                self.publishStats();
                self.publishEvents();
                self.shared.sleeping.store(true, .seq_cst);
                const pending = !self.stalled and !self.shared.commands.isEmpty();
                if (pending or (self.shutdown_deadline == null and self.shared.stop_requested.load(.seq_cst))) wait_ms = 0;
            }

            _ = self.listener.poll(.{ .duration = .{ .raw = .fromMilliseconds(@intCast(@min(wait_ms, 60_000))), .clock = .awake } }, self.callbacks()) catch |err| {
                if (err == error.ConnectionClosed) return;
                self.stats.transport_errors += 1;
                self.io.sleep(.fromMilliseconds(1), .awake) catch {};
            };
            self.shared.sleeping.store(false, .seq_cst);

            self.drainReceipts();
            const after = self.clock();
            if (after >= self.next_ping_ms) {
                self.emitPings();
                self.next_ping_ms = after + self.config.ping_interval_ms;
            }
            self.publishStats();
            self.publishEvents();
        }
    }

    fn finish(self: *Worker) void {
        self.listener.closeWithCallbacks(self.callbacks());
        self.drainReceipts();
        self.publishStats();
        self.publishEvents();
        self.shared.exited.store(true, .seq_cst);
        self.wakeConsumer();
    }

    fn beginShutdown(self: *Worker, now: u64) void {
        for (self.slots) |*slot| if (slot.live) {
            slot.reason = .shutdown;
            slot.closing = true;
        };
        self.listener.beginShutdown();
        self.shutdown_deadline = now + self.shared.stop_timeout_ms.load(.monotonic);
    }

    fn callbacks(self: *Worker) Callbacks {
        return .{
            .context = self,
            .connected = onConnected,
            .message = onMessage,
            .disconnected = onDisconnected,
            .filter_datagram = filterDatagram,
        };
    }

    fn clock(self: *Worker) u64 {
        const ns = std.Io.Clock.awake.now(self.io).nanoseconds;
        return @intCast(@divTrunc(ns, std.time.ns_per_ms));
    }

    fn obligationReserve(self: *const Worker, extra: usize) usize {
        return (self.active + self.receipts + extra) * obligation_bytes;
    }

    fn emit(self: *Worker, event: Event, len: usize) ?[]u8 {
        return self.shared.events.reserve(@backingInt(event), len, self.obligationReserve(0));
    }

    fn emitHeld(self: *Worker, event: Event, session: u64, value: u64) void {
        const bytes = self.shared.events.reserve(@backingInt(event), 16, 0) orelse return;
        std.mem.writeInt(u64, bytes[0..8], session, .little);
        std.mem.writeInt(u64, bytes[8..16], value, .little);
        self.commitEvent();
    }

    fn commitEvent(self: *Worker) void {
        self.shared.events.commit();
        self.dirty = true;
    }

    fn publishEvents(self: *Worker) void {
        if (!self.dirty) return;
        self.dirty = false;
        self.shared.events.publish();
        self.wakeConsumer();
    }

    fn wakeConsumer(self: *Worker) void {
        self.shared.notifyConsumer(self.io);
    }

    fn publishStats(self: *Worker) void {
        const traffic = self.listener.socket.traffic;
        self.stats.sessions = self.active;
        self.stats.bytes_sent = traffic.bytes_sent;
        self.stats.bytes_received = traffic.bytes_received;
        self.stats.datagrams_sent = traffic.datagrams_sent;
        self.stats.datagrams_received = traffic.datagrams_received;
        self.shared.storeStats(self.stats);
    }

    fn indexOf(self: *const Worker, slot: *const Slot) u32 {
        return @intCast((@intFromPtr(slot) - @intFromPtr(self.slots.ptr)) / @sizeOf(Slot));
    }

    fn sessionId(self: *const Worker, slot: *const Slot) u64 {
        return host_mod.sessionId(self.indexOf(slot), slot.generation);
    }

    fn slotOf(rak: *raknet.Session) ?*Slot {
        return @ptrCast(@alignCast(rak.userData() orelse return null));
    }

    fn resolve(self: *Worker, id: u64) ?struct { slot: *Slot, rak: *raknet.Session } {
        const parts = host_mod.sessionParts(id) orelse return null;
        if (parts.index >= self.slots.len) return null;
        const slot = &self.slots[parts.index];
        if (!slot.live or slot.closing or slot.generation != parts.generation) return null;
        const rak = self.listener.lookupSession(slot.handle) orelse return null;
        return .{ .slot = slot, .rak = rak };
    }

    fn fail(self: *Worker, slot: *Slot, rak: ?*raknet.Session, reason: Reason) void {
        if (!slot.closing) {
            slot.reason = reason;
            slot.closing = true;
            switch (reason) {
                .protocol => self.stats.protocol_disconnects += 1,
                .overload => self.stats.overload_disconnects += 1,
                else => {},
            }
        }
        slot.session.close();
        if (rak) |session| session.closeNow();
    }

    fn onConnected(context: *anyopaque, rak: *raknet.Session) error{ApplicationFailure}!void {
        const self: *Worker = @ptrCast(@alignCast(context));
        if (self.shutdown_deadline != null or self.free_len == 0) {
            self.stats.connections_refused += 1;
            return error.ApplicationFailure;
        }
        var text_buffer: [address_mod.max_text]u8 = undefined;
        const text = address_mod.format(rak.address, &text_buffer);
        const bytes = self.shared.events.reserve(@backingInt(Event.connect), 18 + text.len, self.obligationReserve(1)) orelse {
            self.stats.connections_refused += 1;
            return error.ApplicationFailure;
        };

        const index = self.free[self.free_len - 1];
        const slot = &self.slots[index];
        slot.session = bedwire.Session.init(.server, .{ .pool = &self.pool, .policy = self.policy }) catch {
            self.stats.connections_refused += 1;
            return error.ApplicationFailure;
        };
        self.free_len -= 1;
        slot.generation +%= 1;
        if (slot.generation == 0) slot.generation = 1;
        slot.live = true;
        slot.closing = false;
        slot.reason = .remote;
        slot.handle = rak.sessionHandle();
        slot.tokens = self.config.packet_rate;
        slot.refilled_ms = self.clock();
        rak.setUserData(slot);
        self.active += 1;

        const id = host_mod.sessionId(index, slot.generation);
        std.mem.writeInt(u64, bytes[0..8], id, .little);
        std.mem.writeInt(u64, bytes[8..16], rak.client_guid, .little);
        std.mem.writeInt(u16, bytes[16..18], rak.address.getPort(), .little);
        @memcpy(bytes[18..], text);
        self.commitEvent();
        self.shared.live[index].store(slot.generation, .release);
    }

    fn onDisconnected(context: *anyopaque, rak: *raknet.Session) void {
        const self: *Worker = @ptrCast(@alignCast(context));
        const slot = slotOf(rak) orelse return;
        rak.setUserData(null);
        const id = self.sessionId(slot);
        while (rak.pollSendReceipt()) |receipt| self.completeReceipt(slot, receipt);
        for (slot.receipts.items) |pending| self.emitHeld(.receipt_failed, id, pending.id);
        self.receipts -= slot.receipts.items.len;
        slot.receipts.clearRetainingCapacity();
        const index = self.indexOf(slot);
        if (std.mem.indexOfScalar(u32, self.receipt_slots.items, index)) |i| _ = self.receipt_slots.swapRemove(i);

        const bytes = self.shared.events.reserve(@backingInt(Event.disconnect), 9, 0);
        if (bytes) |out| {
            std.mem.writeInt(u64, out[0..8], id, .little);
            out[8] = @backingInt(slot.reason);
            self.commitEvent();
        }
        self.shared.live[index].store(0, .release);
        slot.session.deinit();
        slot.live = false;
        slot.closing = false;
        self.free[self.free_len] = index;
        self.free_len += 1;
        self.active -= 1;
    }

    fn onMessage(context: *anyopaque, rak: *raknet.Session, payload: raknet.BorrowedPayload) error{ApplicationFailure}!void {
        const self: *Worker = @ptrCast(@alignCast(context));
        const slot = slotOf(rak) orelse return;
        if (slot.closing) return;
        self.ingest(slot, payload.bytes) catch |err| {
            self.fail(slot, null, switch (err) {
                error.EventQueueFull, error.PacketRate => .overload,
                else => .protocol,
            });
            return error.ApplicationFailure;
        };
    }

    fn ingest(self: *Worker, slot: *Slot, payload: []const u8) !void {
        var packets = try slot.session.ingest(payload);
        defer packets.deinit();
        const id = self.sessionId(slot);

        var next: ?bedwire.State = null;
        while (packets.next()) |packet| {
            if (!self.takeToken(slot)) return error.PacketRate;
            if (packet.kind) |kind| switch (kind) {
                .client_to_server_handshake => if (slot.session.state == .encrypted_handshake) {
                    next = .resource_packs;
                },
                .resource_pack_client_response => if (slot.session.state == .resource_packs and stackFinished(&slot.session, packet)) {
                    next = .waiting_for_start_game;
                },
                .set_local_player_as_initialised => if (slot.session.state == .spawn_ready) {
                    next = .in_game;
                },
                else => {},
            };
            const bytes = self.emit(.packet, 8 + packet.bytes.len) orelse return error.EventQueueFull;
            std.mem.writeInt(u64, bytes[0..8], id, .little);
            @memcpy(bytes[8..], packet.bytes);
            self.commitEvent();
            self.stats.packets_received += 1;
        }
        if (next) |state| try slot.session.advance(state);
    }

    fn stackFinished(session: *bedwire.Session, packet: bedwire.Packet) bool {
        const decoded = session.decodePacket(packet) catch return false;
        if (decoded.value != .typed or decoded.value.typed != .resource_pack_client_response) return false;
        return decoded.value.typed.resource_pack_client_response.response == .resource_pack_stack_finished;
    }

    fn takeToken(self: *Worker, slot: *Slot) bool {
        const rate = self.config.packet_rate;
        if (rate == 0) return true;
        if (slot.tokens == 0) {
            const now_ms = self.clock();
            const elapsed = now_ms -| slot.refilled_ms;
            const refill = @min(@as(u64, rate), elapsed * rate / 1000);
            if (refill == 0) return false;
            slot.tokens = @intCast(refill);
            slot.refilled_ms = now_ms;
        }
        slot.tokens -= 1;
        return true;
    }

    fn filterDatagram(context: *anyopaque, remote: std.Io.net.IpAddress, data: []const u8, now_ms: u64) bool {
        const self: *Worker = @ptrCast(@alignCast(context));
        if (data.len == self.shared.wake_token.len and std.mem.eql(u8, data, &self.shared.wake_token)) return false;
        if (self.blocked.count() != 0) {
            const key = address_mod.key(remote);
            if (self.blocked.get(key)) |expiry| {
                if (now_ms < expiry) {
                    self.stats.blocked_dropped += 1;
                    return false;
                }
                _ = self.blocked.remove(key);
            }
        }
        for (self.raw_lens, 0..) |len, i| {
            if (len == 0) break;
            if (!std.mem.startsWith(u8, data, self.raw_prefixes[i][0..len])) continue;
            self.forwardRaw(remote, data, now_ms);
            return false;
        }
        return true;
    }

    fn forwardRaw(self: *Worker, remote: std.Io.net.IpAddress, data: []const u8, now_ms: u64) void {
        if (self.raw_tokens == 0) {
            const refill = @min(@as(u64, self.config.raw_rate), (now_ms -| self.raw_refilled_ms) * self.config.raw_rate / 1000);
            if (refill != 0) {
                self.raw_tokens = @intCast(refill);
                self.raw_refilled_ms = now_ms;
            }
        }
        var text_buffer: [address_mod.max_text]u8 = undefined;
        const text = address_mod.format(remote, &text_buffer);
        const bytes = if (self.raw_tokens != 0) self.emit(.raw, 16 + text.len + data.len) else null;
        const out = bytes orelse {
            self.stats.raw_dropped += 1;
            return;
        };
        self.raw_tokens -= 1;
        std.mem.writeInt(u64, out[0..8], remote.getPort(), .little);
        std.mem.writeInt(u64, out[8..16], text.len, .little);
        @memcpy(out[16..][0..text.len], text);
        @memcpy(out[16 + text.len ..], data);
        self.commitEvent();
    }

    fn emitPings(self: *Worker) void {
        for (self.slots, 0..) |*slot, i| {
            if (!slot.live or slot.closing) continue;
            const rak = self.listener.lookupSession(slot.handle) orelse continue;
            const rtt = rak.statistics().smoothed_rtt_ms orelse continue;
            const bytes = self.emit(.ping, 16) orelse return;
            std.mem.writeInt(u64, bytes[0..8], host_mod.sessionId(@intCast(i), slot.generation), .little);
            std.mem.writeInt(u64, bytes[8..16], rtt, .little);
            self.commitEvent();
        }
    }

    fn drainReceipts(self: *Worker) void {
        var i: usize = 0;
        while (i < self.receipt_slots.items.len) {
            const slot = &self.slots[self.receipt_slots.items[i]];
            if (slot.live) if (self.listener.lookupSession(slot.handle)) |rak| {
                while (rak.pollSendReceipt()) |receipt| self.completeReceipt(slot, receipt);
            };
            if (slot.receipts.items.len == 0) {
                _ = self.receipt_slots.swapRemove(i);
            } else i += 1;
        }
    }

    fn completeReceipt(self: *Worker, slot: *Slot, receipt: raknet.SendReceipt) void {
        for (slot.receipts.items, 0..) |pending, i| {
            if (pending.handle.id != receipt.handle.id or pending.handle.owner != receipt.handle.owner) continue;
            _ = slot.receipts.swapRemove(i);
            self.receipts -= 1;
            self.emitHeld(if (receipt.outcome == .acknowledged) .receipt_ack else .receipt_failed, self.sessionId(slot), pending.id);
            return;
        }
    }

    fn processCommands(self: *Worker) bool {
        const ring = &self.shared.commands;
        defer ring.release();
        self.stalled = false;
        for (0..commands_per_turn) |_| {
            const mark = ring.position();
            const record = ring.next() orelse return false;
            if (self.dispatch(@fromBackingInt(@intCast(record.tag)), record.bytes) == .stall) {
                ring.rewind(mark);
                self.stalled = true;
                self.shared.wants_events_space.store(true, .seq_cst);
                // PHP may have freed space before it saw the flag.
                if (self.shared.events.available() < self.obligationReserve(1)) return true;
                self.shared.wants_events_space.store(false, .seq_cst);
                self.stalled = false;
                continue;
            }
        }
        return !ring.isEmpty();
    }

    fn dispatch(self: *Worker, command: Command, bytes: []u8) Outcome {
        switch (command) {
            .send => return self.handleSend(bytes),
            .disconnect => if (self.resolve(std.mem.readInt(u64, bytes[0..8], .little))) |target| {
                target.slot.reason = .server;
                target.slot.closing = true;
                target.slot.session.beginClose();
                target.rak.close();
            },
            .encrypt => {
                const key = bytes[8..][0..host_mod.key_len];
                defer std.crypto.secureZero(u8, key);
                const target = self.resolve(std.mem.readInt(u64, bytes[0..8], .little)) orelse return .done;
                _ = self.sendPackets(target.slot, target.rak, &.{bytes[8 + host_mod.key_len ..]}, 0) catch return .done;
                target.slot.session.installServerKey(key.*) catch self.fail(target.slot, target.rak, .protocol);
            },
            .accept_login => {
                const target = self.resolve(std.mem.readInt(u64, bytes[0..8], .little)) orelse return .done;
                const key = bedwire.crypto.spki.decode(bytes[8..]) catch return self.reject(target.slot, target.rak);
                target.slot.session.installVerifiedClientKey(key) catch return self.reject(target.slot, target.rak);
                if (!self.config.encryption) target.slot.session.advance(.resource_packs) catch return self.reject(target.slot, target.rak);
            },
            .advertise => self.listener.setAdvertisement(bytes) catch {},
            .block => {
                const duration = std.mem.readInt(u64, bytes[0..8], .little);
                const key = bytes[8..][0..@sizeOf(address_mod.Key)].*;
                if (self.blocked.count() >= self.config.max_blocked and !self.blocked.contains(key)) self.purgeBlocked();
                if (self.blocked.count() < self.config.max_blocked or self.blocked.contains(key)) {
                    self.blocked.putAssumeCapacity(key, self.clock() +| duration);
                }
            },
            .unblock => _ = self.blocked.remove(bytes[0..@sizeOf(address_mod.Key)].*),
            .raw_send => {
                var remote: std.Io.net.IpAddress = undefined;
                @memcpy(std.mem.asBytes(&remote), bytes[0..@sizeOf(std.Io.net.IpAddress)]);
                self.listener.sendRaw(remote, bytes[@sizeOf(std.Io.net.IpAddress)..]) catch {};
            },
        }
        return .done;
    }

    fn reject(self: *Worker, slot: *Slot, rak: *raknet.Session) Outcome {
        self.fail(slot, rak, .protocol);
        return .done;
    }

    fn purgeBlocked(self: *Worker) void {
        const now_ms = self.clock();
        var iterator = self.blocked.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* <= now_ms) self.blocked.removeByPtr(entry.key_ptr);
        }
    }

    fn handleSend(self: *Worker, bytes: []u8) Outcome {
        const id = std.mem.readInt(u64, bytes[0..8], .little);
        const receipt = std.mem.readInt(u64, bytes[8..16], .little);
        // A receipt always ends in an event so make room before doing anything.
        if (receipt != 0 and self.shared.events.available() < self.obligationReserve(1)) return .stall;

        const target = self.resolve(id) orelse {
            if (receipt != 0) self.emitHeld(.receipt_failed, id, receipt);
            return .done;
        };
        var packets: [host_mod.max_packets_per_batch][]const u8 = undefined;
        var count: usize = 0;
        var total: usize = 0;
        _ = self.gather(bytes, &packets, &count, &total);

        // Merge sends already queued for this session into one frame.
        if (receipt == 0) {
            const ring = &self.shared.commands;
            while (true) {
                const mark = ring.position();
                const next = ring.next() orelse break;
                const merged = next.tag == @backingInt(Command.send) and
                    std.mem.readInt(u64, next.bytes[0..8], .little) == id and
                    std.mem.readInt(u64, next.bytes[8..16], .little) == 0 and
                    self.gather(next.bytes, &packets, &count, &total);
                if (!merged) {
                    ring.rewind(mark);
                    break;
                }
            }
        }
        const sent = self.sendPackets(target.slot, target.rak, packets[0..count], receipt) catch false;
        if (receipt != 0 and !sent) self.emitHeld(.receipt_failed, id, receipt);
        return .done;
    }

    fn gather(self: *const Worker, bytes: []const u8, packets: *[host_mod.max_packets_per_batch][]const u8, count: *usize, total: *usize) bool {
        var added: usize = 0;
        var offset: usize = 16;
        while (offset < bytes.len) : (added += 1) offset += 4 + std.mem.readInt(u32, bytes[offset..][0..4], .little);
        const size = bytes.len - 16;
        const limit = @min(self.config.max_batch_bytes, host_mod.max_frame_bytes - 64);
        if (count.* != 0 and (count.* + added > packets.len or total.* + size > limit)) return false;
        offset = 16;
        while (offset < bytes.len) : (count.* += 1) {
            const len = std.mem.readInt(u32, bytes[offset..][0..4], .little);
            packets[count.*] = bytes[offset + 4 ..][0..len];
            offset += 4 + len;
        }
        total.* += size;
        return true;
    }

    fn sendPackets(self: *Worker, slot: *Slot, rak: *raknet.Session, packets: []const []const u8, receipt: u64) !bool {
        var tracked = false;
        var len: usize = 0;
        for (packets, 0..) |packet, i| {
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

            if (try self.flushGroup(slot, rak, len, if (i + 1 == packets.len) receipt else 0)) tracked = true;
            len = 0;
            if (kind == .network_settings) {
                slot.session.negotiateFromSettings(.{ .kind = kind, .id = header.header.packet_id, .bytes = packet }) catch |err| {
                    self.fail(slot, rak, .protocol);
                    return err;
                };
            } else if (kind == .start_game and slot.session.state == .waiting_for_start_game) {
                try slot.session.advance(.spawn_ready);
            }
        }
        if (len != 0 and try self.flushGroup(slot, rak, len, receipt)) tracked = true;
        return tracked;
    }

    fn flushGroup(self: *Worker, slot: *Slot, rak: *raknet.Session, len: usize, receipt: u64) !bool {
        const frame = slot.session.encode(self.group[0..len]) catch |err| {
            self.fail(slot, rak, .protocol);
            return err;
        };
        defer frame.release();
        self.stats.batches_sent += 1;
        if (receipt == 0) {
            rak.send(frame.bytes, .reliable_ordered, 0) catch |err| {
                self.fail(slot, rak, .overload);
                return err;
            };
            return false;
        }
        slot.receipts.ensureUnusedCapacity(self.allocator, 1) catch |err| {
            self.fail(slot, rak, .overload);
            return err;
        };
        const handle = rak.queueSendWithReceipt(frame.bytes, .reliable_ordered, 0) catch |err| {
            self.fail(slot, rak, .overload);
            return err;
        };
        slot.receipts.appendAssumeCapacity(.{ .handle = handle, .id = receipt });
        if (slot.receipts.items.len == 1) self.receipt_slots.appendAssumeCapacity(self.indexOf(slot));
        self.receipts += 1;
        return true;
    }
};
