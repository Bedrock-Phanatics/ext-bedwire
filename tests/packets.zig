const std = @import("std");
const bedwire = @import("bedwire");

const control = bedwire.control;

pub const protocol_version: u32 = 2225;
pub const minecraft_version = "1.26.60";
/// Text, which Bedwire treats as opaque gameplay.
pub const text: u10 = 9;

pub const Compression = control.NetworkSettings.Algorithm;

pub fn id(kind: bedwire.PacketKind) u10 {
    return kind.id();
}

pub fn raw(storage: []u8, packet_id: u10, body: []const u8) []const u8 {
    const len = bedwire.framing.varint.writeU32(storage, packet_id) catch unreachable;
    @memmove(storage[len..][0..body.len], body);
    return storage[0 .. len + body.len];
}

fn encode(storage: []u8, value: anytype) []const u8 {
    return control.encode(storage, value) catch unreachable;
}

pub fn request(storage: []u8) []const u8 {
    return encode(storage, control.RequestNetworkSettings{ .protocol_version = @intCast(protocol_version) });
}

pub fn login(storage: []u8) []const u8 {
    return encode(storage, control.Login{ .protocol_version = @intCast(protocol_version), .connection_request = "fixture" });
}

pub fn networkSettings(storage: []u8, algorithm: Compression, threshold: u16) []const u8 {
    return encode(storage, control.NetworkSettings{ .compression_threshold = threshold, .compression_algorithm = algorithm });
}

pub fn playStatus(storage: []u8) []const u8 {
    return encode(storage, control.PlayStatus{ .status = control.PlayStatus.login_success });
}

/// An empty 1.26.60 pack offer, which Bedwire passes through undecoded.
pub fn resourcePacksInfo(storage: []u8) []const u8 {
    return raw(storage, id(.resource_packs_info), &@as([22]u8, @splat(0)));
}

pub fn resourcePackStack(storage: []u8) []const u8 {
    return raw(storage, id(.resource_pack_stack), &@as([9]u8, @splat(0)));
}

pub const runtime_id: u64 = 1;

/// Only the leading unique and runtime IDs, which is all a session reads from StartGame.
pub fn startGame(storage: []u8) []const u8 {
    return raw(storage, id(.start_game), "\x02\x01");
}

pub fn playerSpawn(storage: []u8) []const u8 {
    return encode(storage, control.PlayStatus{ .status = control.PlayStatus.player_spawn });
}

pub fn initialised(storage: []u8) []const u8 {
    return encode(storage, control.SetLocalPlayerAsInitialised{ .runtime_id = runtime_id });
}

pub fn stackFinished(storage: []u8) []const u8 {
    return encode(storage, control.ResourcePackClientResponse{ .status = .resource_pack_stack_finished, .text = "resourcepackstackfinished" });
}
