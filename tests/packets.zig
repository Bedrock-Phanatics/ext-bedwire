const std = @import("std");
const bedwire = @import("bedwire");

const protocol = bedwire.protocol;
const Profile = protocol.Current;

pub const Compression = @FieldType(@FieldType(protocol.typed.Packet, "network_settings"), "compression_algorithm");

pub fn id(kind: bedwire.PacketKind) u10 {
    return Profile.packetId(kind).?;
}

pub fn raw(storage: []u8, packet_id: u10, body: []const u8) []const u8 {
    const len = bedwire.framing.varint.writeU32(storage, packet_id) catch unreachable;
    @memmove(storage[len..][0..body.len], body);
    return storage[0 .. len + body.len];
}

pub fn typed(storage: []u8, packet: protocol.typed.Packet) []const u8 {
    var writer = protocol.Writer.init(storage);
    protocol.typed.encode(&writer, .{ .header = .{ .packet_id = id(protocol.typed.packetKind(packet)) }, .packet = packet }) catch unreachable;
    return writer.written();
}

fn envelope(storage: []u8, kind: bedwire.PacketKind, value: protocol.typed.Packet) []const u8 {
    var writer = protocol.Writer.init(storage);
    Profile.encode(&writer, .{ .header = .{ .packet_id = id(kind) }, .kind = kind, .payload = &.{}, .value = .{ .typed = value } }) catch unreachable;
    return writer.written();
}

pub fn request(storage: []u8) []const u8 {
    return typed(storage, .{ .request_network_settings = .{ .client_network_version = Profile.protocol_number } });
}

pub fn login(storage: []u8) []const u8 {
    return typed(storage, .{ .login = .{ .client_network_version = Profile.protocol_number, .connection_request = "fixture" } });
}

pub fn networkSettings(storage: []u8, algorithm: Compression, threshold: u16) []const u8 {
    return envelope(storage, .network_settings, .{ .network_settings = .{
        .compression_threshold = threshold,
        .compression_algorithm = algorithm,
        .client_throttle_enabled = false,
        .client_throttle_threshold = 0,
        .client_throttle_scalar = 0,
    } });
}

pub fn resourcePacksInfo(storage: []u8) []const u8 {
    return envelope(storage, .resource_packs_info, .{ .resource_packs_info = .{
        .resource_pack_required = false,
        .has_addon_packs = false,
        .has_scripts = false,
        .force_disable_vibrant_visuals = false,
        .world_template_id_and_version = .{ .pack_uuid = @splat(0), .pack_version = "" },
        .resource_packs = .empty,
    } });
}

pub fn stackFinished(storage: []u8) []const u8 {
    return envelope(storage, .resource_pack_client_response, .{ .resource_pack_client_response = .{
        .response = .{ .resource_pack_stack_finished = "resourcepackstackfinished" },
    } });
}
