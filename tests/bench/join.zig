//! Joins a server like an offline vanilla client: `join <port> <name> [seconds] [record]`.
//! It logs in with a self-signed identity, accepts the packs, spawns, stays for the given time and prints one JSON line.
//! With a record file it also writes every server packet as `<id> <hex>`. BEDWIRE_PROTOCOL and BEDWIRE_MINECRAFT_VERSION
//! set the version it announces.
const std = @import("std");
const bedwire = @import("bedwire");
const peer_mod = @import("peer.zig");

const control = bedwire.control;
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

    const protocol_version = if (init.environ_map.get("BEDWIRE_PROTOCOL")) |text| try std.fmt.parseInt(i32, text, 10) else peer_mod.protocol_version;
    const minecraft_version = init.environ_map.get("BEDWIRE_MINECRAFT_VERSION") orelse peer_mod.minecraft_version;

    var storage: [512]u8 = undefined;
    try peer.send(&.{try control.encode(&storage, control.RequestNetworkSettings{ .protocol_version = protocol_version })});

    var join: Join = .{
        .peer = peer,
        .name = name,
        .protocol_version = protocol_version,
        .minecraft_version = minecraft_version,
        .record = if (record_writer) |*writer| &writer.interface else null,
    };
    const deadline = start + 30 * std.time.ns_per_s;
    var stay_until: ?u64 = null;
    while (true) {
        const now = peer_mod.nowNs(io);
        if (stay_until) |end| {
            if (now >= end) break;
        } else if (join.spawned_ns != null) {
            stay_until = now + @as(u64, seconds) * std.time.ns_per_s;
        } else if (now > deadline) return fail("timed out in state {t}", .{peer.session.state});

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
    protocol_version: i32,
    minecraft_version: []const u8,
    runtime_id: u64 = 0,
    packets: usize = 0,
    chunks: usize = 0,
    spawned_ns: ?u64 = null,
    record: ?*std.Io.Writer = null,

    fn write(self: *Join, packet: anytype) !void {
        const writer = self.record orelse return;
        try writer.print("{d} {x}\n", .{ packet.id, packet.bytes });
    }

    fn deliver(self: *Join, payload: []const u8) !void {
        var batch = self.peer.session.ingest(payload) catch |err| return fail("rejected a server batch in state {t}: {t}", .{ self.peer.session.state, err });
        defer batch.deinit();
        var storage: [64]u8 = undefined;
        while (batch.next()) |packet| {
            self.packets += 1;
            try self.write(packet);
            if (packet.id == level_chunk_id) self.chunks += 1;
            const kind = packet.kind orelse continue;
            switch (kind) {
                .network_settings => {
                    try self.peer.session.negotiateFromSettings(packet);
                    try self.sendLogin();
                },
                .play_status => {
                    const status = (try self.peer.session.decodeControl(control.PlayStatus, packet)).status;
                    switch (status) {
                        control.PlayStatus.login_success => {},
                        control.PlayStatus.player_spawn => if (self.spawned_ns == null) {
                            try self.peer.send(&.{try control.encode(&storage, control.SetLocalPlayerAsInitialised{ .runtime_id = self.runtime_id })});
                            try self.peer.session.advance(.in_game);
                            self.spawned_ns = peer_mod.nowNs(self.peer.io);
                        },
                        else => return fail("login refused with status {d}", .{status}),
                    }
                },
                .resource_packs_info => try self.peer.send(&.{try control.encode(&storage, control.ResourcePackClientResponse{ .status = .downloading_finished, .text = "downloadingfinished" })}),
                .resource_pack_stack => {
                    try self.peer.send(&.{try control.encode(&storage, control.ResourcePackClientResponse{ .status = .resource_pack_stack_finished, .text = "resourcepackstackfinished" })});
                    try self.peer.session.advance(.waiting_for_start_game);
                },
                .start_game => {
                    self.runtime_id = (try self.peer.session.decodeControl(control.StartGame, packet)).runtime_id;
                    try self.peer.session.advance(.spawn_ready);
                    // A radius of 4 as a zigzag varint, then the maximum radius.
                    try self.peer.send(&.{peer_mod.raw(&storage, control.PacketKind.request_chunk_radius.id(), "\x08\x04")});
                },
                .disconnect => return fail("disconnected: {x}", .{packet.bytes}),
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

        const client_data_payload = try clientData(self.name, &uuid, self.minecraft_version);
        defer allocator.free(client_data_payload);
        const client_data = try login.sign(allocator, key, header, client_data_payload, limits);
        defer allocator.free(client_data);

        const envelope = try std.fmt.allocPrint(allocator, "{{\"AuthenticationType\":2,\"Token\":\"{s}\"}}", .{token});
        defer allocator.free(envelope);
        const request = try bedwire.auth.encodeConnectionRequest(allocator, .{ .chain_data = envelope, .client_data = client_data }, limits);
        defer allocator.free(request);
        const packet = try allocator.alloc(u8, request.len + 32);
        defer allocator.free(packet);
        try self.peer.send(&.{try login.encodeLoginPacket(@intCast(self.protocol_version), packet, request, limits)});
    }
};

const level_chunk_id = 58;

fn clientData(name: []const u8, uuid: []const u8, minecraft_version: []const u8) ![]u8 {
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
    , .{ uuid, minecraft_version, uuid, &skin_text, &patch_text, std.json.fmt(name, .{}) });
}
