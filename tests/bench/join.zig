//! Joins a server like an offline vanilla client: `join <port> <name> [seconds] [record]`.
//! It logs in with a self-signed identity, accepts the packs, spawns, stays for the given time and prints one JSON line.
//! With a record file it also decodes every server packet strictly, writes each one as `<id> <hex>`, and plays a little
//! after spawning: it walks, chats and runs a command.
const std = @import("std");
const bedwire = @import("bedwire");
const peer_mod = @import("peer.zig");

const protocol = bedwire.protocol;
const login = bedwire.auth.login;
const allocator = std.heap.smp_allocator;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3 or args.len > 5) return error.Usage;
    const port = try std.fmt.parseInt(u16, args[1], 10);
    const name = args[2];
    const seconds = if (args.len >= 4) try std.fmt.parseInt(u32, args[3], 10) else 3;

    var record_buffer: [64 * 1024]u8 = undefined;
    const record_file = if (args.len == 5) try std.Io.Dir.cwd().createFile(io, args[4], .{}) else null;
    defer if (record_file) |file| file.close(io);
    var record_writer = if (record_file) |file| file.writer(io, &record_buffer) else null;

    var pool = try peer_mod.clientPool(allocator);
    defer pool.deinit();
    const start = peer_mod.nowNs(io);
    const peer = try peer_mod.Peer.connect(allocator, io, port, &pool, null);
    defer peer.destroy();

    var storage: [512]u8 = undefined;
    try peer.send(&.{peer_mod.typed(&storage, .{ .request_network_settings = .{ .client_network_version = protocol.Current.protocol_number } })});

    var join: Join = .{ .peer = peer, .name = name, .record = if (record_writer) |*writer| &writer.interface else null };
    const deadline = start + 30 * std.time.ns_per_s;
    var stay_until: ?u64 = null;
    while (true) {
        const now = peer_mod.nowNs(io);
        if (stay_until) |end| {
            if (now >= end) break;
        } else if (join.spawned_ns != null) {
            stay_until = now + @as(u64, seconds) * std.time.ns_per_s;
        } else if (now > deadline) return fail("timed out in state {t}", .{peer.session.state});
        if (join.record != null and join.spawned_ns != null) try join.play(now);

        const token = peer.connection.prepareWait();
        while (peer.connection.poll() catch return fail("connection closed in state {t}", .{peer.session.state})) |event| {
            if (event == .message) try join.deliver(event.message.data);
        }
        peer.connection.peer.wakeup.wait(io, token, .{ .duration = .{ .raw = .fromMilliseconds(5), .clock = .awake } }) catch {};
    }

    if (join.record) |writer| try writer.flush();
    var out: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &.{});
    try stdout.interface.writeAll(try std.fmt.bufPrint(&out, "{{\"spawn_ms\":{d:.1},\"packets\":{d},\"chunks\":{d}}}\n", .{
        @as(f64, @floatFromInt(join.spawned_ns.? - start)) / 1e6,
        join.packets,
        join.chunks,
    }));
}

fn fail(comptime format: []const u8, args: anytype) error{JoinFailed} {
    std.debug.print("join: " ++ format ++ "\n", args);
    return error.JoinFailed;
}

const Join = struct {
    peer: *peer_mod.Peer,
    name: []const u8,
    runtime_id: u64 = 0,
    packets: usize = 0,
    chunks: usize = 0,
    spawned_ns: ?u64 = null,
    record: ?*std.Io.Writer = null,
    position: protocol.Vec3f = .{ .x = 0, .y = 0, .z = 0 },
    tick: u64 = 0,
    next_input_ns: u64 = 0,

    /// Sends an input every 50 ms, like a client standing still, then a chat line and a command once.
    fn play(self: *Join, now: u64) !void {
        if (now < self.next_input_ns) return;
        self.next_input_ns = now + 50 * std.time.ns_per_ms;
        var storage: [512]u8 = undefined;
        const zero: protocol.Vec2f = .{ .x = 0, .y = 0 };
        try self.peer.send(&.{peer_mod.typed(&storage, .{ .player_auth_input = .{
            .player_rotation = zero,
            .position = self.position,
            .move_vector = zero,
            .player_head_rotation = 0,
            .input_data = .init(&.{}),
            .input_mode = .mouse,
            .play_mode = .normal,
            .new_interaction_model = .crosshair,
            .interact_rotation = zero,
            .client_tick = self.tick,
            .pos_delta = .{ .x = 0, .y = 0, .z = 0 },
            .item_use_transaction = null,
            .item_stack_request = null,
            .player_block_actions = null,
            .vehicle_rotation = null,
            .client_predicted_vehicle = null,
            .analog_move_vector = zero,
            .camera_orientation = .{ .x = 0, .y = 0, .z = 1 },
            .raw_move_vector = zero,
        } })});
        self.tick += 1;
        if (self.tick == 10) {
            try self.peer.send(&.{peer_mod.typed(&storage, .{ .text = .{
                .localize = false,
                .body = .{ .author_and_message = .{ .message_type = .chat, .player_name = self.name, .message = "hello from bedwire-join" } },
                .senders_xuid = "",
                .platform_id = "",
                .filtered_message = null,
            } })});
            try self.peer.send(&.{peer_mod.typed(&storage, .{ .command_request = .{
                .command = "/version",
                .origin = .{ .type = "player", .uuid = @splat(0), .request_id = "", .player_id = 0 },
                .is_internal = false,
                .version = "latest",
            } })});
        }
    }

    fn write(self: *Join, packet: anytype) !void {
        const writer = self.record orelse return;
        if (packet.kind == null) return fail("server sent unknown packet ID {d}", .{packet.id});
        _ = self.peer.session.decodePacket(packet) catch |err| return fail("server sent a malformed {t}: {t}", .{ packet.kind.?, err });
        try writer.print("{d} {x}\n", .{ packet.id, packet.bytes });
    }

    fn deliver(self: *Join, payload: []const u8) !void {
        var batch = self.peer.session.ingest(payload) catch |err| return fail("rejected a server batch in state {t}: {t}", .{ self.peer.session.state, err });
        defer batch.deinit();
        var storage: [64]u8 = undefined;
        while (batch.next()) |packet| {
            self.packets += 1;
            try self.write(packet);
            const kind = packet.kind orelse continue;
            switch (kind) {
                .network_settings => {
                    try self.peer.session.negotiateFromSettings(packet);
                    try self.sendLogin();
                },
                .play_status => {
                    const status = (try self.peer.session.decodePacket(packet)).value.typed.play_status.status;
                    switch (status) {
                        .loginsuccess => {},
                        .playerspawn => if (self.spawned_ns == null) {
                            try self.peer.send(&.{peer_mod.typed(&storage, .{ .set_local_player_as_initialised = .{ .player_id = self.runtime_id } })});
                            try self.peer.session.advance(.in_game);
                            self.spawned_ns = peer_mod.nowNs(self.peer.io);
                        },
                        else => return fail("login refused with status {d}", .{@backingInt(status)}),
                    }
                },
                .resource_packs_info => try self.peer.send(&.{peer_mod.typed(&storage, .{ .resource_pack_client_response = .{ .response = .{ .downloading_finished = "downloadingfinished" } } })}),
                .resource_pack_stack => {
                    try self.peer.send(&.{peer_mod.typed(&storage, .{ .resource_pack_client_response = .{ .response = .{ .resource_pack_stack_finished = "resourcepackstackfinished" } } })});
                    try self.peer.session.advance(.waiting_for_start_game);
                },
                .start_game => {
                    self.runtime_id = try startGameRuntimeId(packet.bytes);
                    if (self.record != null) self.position = (try self.peer.session.decodePacket(packet)).value.typed.start_game.position;
                    try self.peer.session.advance(.spawn_ready);
                    try self.peer.send(&.{peer_mod.typed(&storage, .{ .request_chunk_radius = .{ .chunk_radius = 4, .max_chunk_radius = 4 } })});
                },
                .level_chunk => self.chunks += 1,
                .disconnect => {
                    const disconnect = (try self.peer.session.decodePacket(packet)).value.typed.disconnect;
                    const message = switch (disconnect.messages) {
                        .messages => |messages| messages.message,
                        .empty => "",
                    };
                    return fail("disconnected with reason {d}: {s}", .{ @backingInt(disconnect.reason), message });
                },
                else => {},
            }
        }
    }

    fn sendLogin(self: *Join) !void {
        const key = self.peer.key;
        const limits: bedwire.Limits = .{};
        const public_key = login.encodedPublicKey(key.public_key);
        var header_storage: [256]u8 = undefined;
        const header = try std.fmt.bufPrint(&header_storage, "{{\"alg\":\"ES384\",\"x5u\":\"{s}\"}}", .{&public_key});

        var random: [16]u8 = undefined;
        self.peer.io.random(&random);
        random[6] = (random[6] & 0x0f) | 0x30;
        random[8] = (random[8] & 0x3f) | 0x80;
        const hex = std.fmt.bytesToHex(random, .lower);
        var uuid: [36]u8 = undefined;
        _ = try std.fmt.bufPrint(&uuid, "{s}-{s}-{s}-{s}-{s}", .{ hex[0..8], hex[8..12], hex[12..16], hex[16..20], hex[20..32] });

        const now = std.Io.Clock.real.now(self.peer.io).toSeconds();
        const claims = try std.fmt.allocPrint(allocator, "{{\"aud\":\"api://auth-minecraft-services/multiplayer\",\"cpk\":\"{s}\",\"exp\":{d},\"iat\":{d},\"nbf\":{d},\"leguuid\":\"{s}\",\"mid\":\"{s}\",\"xname\":{f}}}", .{
            &public_key, now + 3600, now, now - 60, &uuid, &hex, std.json.fmt(self.name, .{}),
        });
        defer allocator.free(claims);
        const token = try login.sign(allocator, key, header, claims, limits);
        defer allocator.free(token);

        const client_data_payload = try clientData(self.name, &uuid);
        defer allocator.free(client_data_payload);
        const client_data = try login.sign(allocator, key, header, client_data_payload, limits);
        defer allocator.free(client_data);

        const envelope = try std.fmt.allocPrint(allocator, "{{\"AuthenticationType\":2,\"Token\":\"{s}\"}}", .{token});
        defer allocator.free(envelope);
        const request = try bedwire.auth.encodeConnectionRequest(allocator, .{ .chain_data = envelope, .client_data = client_data }, limits);
        defer allocator.free(request);
        const packet = try allocator.alloc(u8, request.len + 32);
        defer allocator.free(packet);
        try self.peer.send(&.{try login.encodeLoginPacket(protocol.Current, packet, request, limits)});
    }
};

fn clientData(name: []const u8, uuid: []const u8) ![]u8 {
    const encoder = std.base64.standard.Encoder;
    var skin: [64 * 64 * 4]u8 = undefined;
    @memset(&skin, 0xff);
    var skin_text: [encoder.calcSize(skin.len)]u8 = undefined;
    _ = encoder.encode(&skin_text, &skin);
    const patch = "{\"geometry\":{\"default\":\"geometry.humanoid.custom\"}}";
    var patch_text: [encoder.calcSize(patch.len)]u8 = undefined;
    _ = encoder.encode(&patch_text, patch);

    return std.fmt.allocPrint(allocator,
        \\{{"AnimatedImageData":[],"ArmSize":"wide","CapeData":"","CapeId":"","CapeImageHeight":0,"CapeImageWidth":0,
        \\"CapeOnClassicSkin":false,"ClientEditorConnectionIntent":0,"ClientIsEditorCapable":false,"ClientRandomId":1,
        \\"CompatibleWithClientSideChunkGen":false,"CurrentInputMode":1,"DefaultInputMode":1,"DeviceId":"{s}",
        \\"DeviceModel":"bedwire","DeviceOS":7,"FilterProfanity":false,"GameVersion":"{s}","GraphicsMode":1,"GuiScale":0,
        \\"LanguageCode":"en_US","MaxViewDistance":8,"MemoryTier":2,"PersonaPieces":[],"PersonaSkin":false,"PieceTintColors":[],
        \\"PlatformOfflineId":"","PlatformOnlineId":"","PlatformType":0,"PremiumSkin":false,"ProfileHash":"","SelfSignedId":"{s}",
        \\"ServerAddress":"127.0.0.1","SkinAnimationData":"","SkinColor":"#0","SkinData":"{s}","SkinGeometryData":"",
        \\"SkinGeometryDataEngineVersion":"","SkinId":"bedwire_bot","SkinImageHeight":64,"SkinImageWidth":64,
        \\"SkinResourcePatch":"{s}","ThirdPartyName":{f},"TrustedSkin":false,"UIProfile":0}}
    , .{ uuid, protocol.minecraft_version, uuid, &skin_text, &patch_text, std.json.fmt(name, .{}) });
}

/// StartGame opens with the player's unique ID and then its runtime ID, both varints.
fn startGameRuntimeId(bytes: []const u8) !u64 {
    var offset: usize = 0;
    _ = try varint(bytes, &offset);
    _ = try varint(bytes, &offset);
    return varint(bytes, &offset);
}

fn varint(bytes: []const u8, offset: *usize) !u64 {
    var value: u64 = 0;
    var shift: u7 = 0;
    while (shift < 70) : (shift += 7) {
        if (offset.* >= bytes.len) return error.MalformedStartGame;
        const byte = bytes[offset.*];
        offset.* += 1;
        value |= @as(u64, byte & 0x7f) << @intCast(shift);
        if (byte & 0x80 == 0) return value;
    }
    return error.MalformedStartGame;
}
