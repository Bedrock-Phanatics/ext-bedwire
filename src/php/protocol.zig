const std = @import("std");
const phpz = @import("phpz");
const native = @import("native");
const packet = @import("packet.zig");
const scratch = @import("scratch.zig");

const protocol = native.protocol;
const c = phpz.c;
const zend = phpz.zend;
const Zval = phpz.Zval;
const exception = phpz.exception;

const Kind = packet.Kind;
const PacketRef = phpz.Mixed(&.{ .int, .string });

const limits: protocol.DecodeLimits = .{};

pub const Direction = enum(i64) { clientbound = 1, serverbound = 2, both = 3 };

pub fn directionOf(kind: Kind) Direction {
    return switch (protocol.registry.packetDirection(kind)) {
        .server_to_client => .clientbound,
        .client_to_server => .serverbound,
        .bidirectional => .both,
    };
}

pub const Protocol = struct {
    pub fn __construct() !void {
        return exception.throwError(null, "Bedwire\\Protocol cannot be instantiated", .{});
    }

    pub fn id(packet_name: []const u8) !i64 {
        const kind = packet.kindByName(packet_name) orelse return exception.argumentValueError(1, "must be a known packet name", .{});
        return protocol.registry.packetId(kind).?;
    }

    pub fn name(packet_id: i64) ?*zend.String {
        const kind = kindOf(packet_id) orelse return null;
        return .from(packet.kindName(kind));
    }

    pub fn direction(ref: PacketRef) !i64 {
        return @backingInt(directionOf(try resolve(ref, 1)));
    }

    /// Reads only the header varint, so callers can dispatch before decoding.
    pub fn header(bytes: []const u8) !*zend.Array {
        const value = try readHeader(bytes);
        var list = zend.Array.ListBuilder.init(3);
        list.appendAssumeCapacity(.int, value.packet_id);
        list.appendAssumeCapacity(.int, value.sender_subclient);
        list.appendAssumeCapacity(.int, value.target_subclient);
        return list.finish();
    }

    pub fn packetId(bytes: []const u8) !i64 {
        return (try readHeader(bytes)).packet_id;
    }

    pub fn decode(bytes: []const u8) !?*zend.Array {
        var out: c.zval = undefined;
        if (!try decodeInto(bytes, &out)) return null;
        return Zval.raw.asUnchecked(&out, .array);
    }

    /// Decodes a list of packets in one call, with null for IDs this protocol does not define.
    pub fn decodeMany(packets: *zend.Array) !*zend.Array {
        var list = zend.Array.ListBuilder.init(@intCast(packets.len()));
        var values = packets.fastValueIterator();
        while (values.next()) |raw| {
            const value = deref(raw);
            if (!Zval.raw.is(value, .string)) {
                list.finish().release();
                return exception.argumentTypeError(1, "must contain only strings", .{});
            }
            var out: c.zval = undefined;
            const known = decodeInto(Zval.raw.asUnchecked(value, .string), &out) catch |err| {
                list.finish().release();
                return err;
            };
            if (!known) Zval.raw.set(&out, .null, {});
            list.appendValue(&out);
        }
        return list.finish();
    }

    pub fn encode(ref: PacketRef, fields: *zend.Array, sender_subclient: ?i64, target_subclient: ?i64) !*zend.String {
        const kind = try resolve(ref, 1);
        const sender = std.math.cast(u2, sender_subclient orelse 0) orelse return exception.argumentValueError(3, "must be between 0 and 3", .{});
        const target = std.math.cast(u2, target_subclient orelse 0) orelse return exception.argumentValueError(4, "must be between 0 and 3", .{});
        var zv = Zval.raw.init(.array, fields);
        return encodeValue(kind, &zv, sender, target, 2);
    }

    /// Encodes `[packet, fields]` pairs in one call.
    pub fn encodeMany(packets: *zend.Array) !*zend.Array {
        var list = zend.Array.ListBuilder.init(@intCast(packets.len()));
        errdefer list.finish().release();
        var values = packets.fastValueIterator();
        while (values.next()) |raw| {
            const pair = try pairOf(deref(raw), 1);
            const kind = try resolveZval(pair.ref, 1);
            list.append(.str, try encodeValue(kind, pair.fields, 0, 0, 1));
        }
        return list.finish();
    }
};

pub const Pair = struct { ref: *c.zval, fields: *c.zval };

pub fn pairOf(value: *c.zval, arg: u32) !Pair {
    if (Zval.raw.is(value, .array)) {
        const array = Zval.raw.asUnchecked(value, .array);
        if (array.len() == 2) {
            const ref = array.findIndex(0);
            const fields = array.findIndex(1);
            if (ref != null and fields != null) return .{ .ref = deref(ref.?), .fields = deref(fields.?) };
        }
    }
    return exception.argumentTypeError(arg, "must contain [packet, fields] pairs", .{});
}

fn kindOf(packet_id: i64) ?Kind {
    const value = std.math.cast(u10, packet_id) orelse return null;
    return protocol.registry.packetKind(value);
}

fn resolve(ref: PacketRef, arg: u32) !Kind {
    return switch (ref) {
        .int => |value| kindOf(value) orelse exception.argumentValueError(arg, "must be a known packet ID", .{}),
        .string => |value| packet.kindByName(value) orelse exception.argumentValueError(arg, "must be a known packet name", .{}),
    };
}

pub fn resolveZval(ref: *c.zval, arg: u32) !Kind {
    if (Zval.raw.is(ref, .int)) return kindOf(Zval.raw.asUnchecked(ref, .int)) orelse exception.argumentValueError(arg, "must use known packet IDs", .{});
    if (Zval.raw.is(ref, .string)) return packet.kindByName(Zval.raw.asUnchecked(ref, .string)) orelse exception.argumentValueError(arg, "must use known packet names", .{});
    return exception.argumentTypeError(arg, "must use packet IDs or names", .{});
}

fn readHeader(bytes: []const u8) !protocol.packet.Header {
    const envelope = protocol.packet.decode(bytes, limits) catch |err| return malformed(err);
    return envelope.header;
}

/// Returns false for packet IDs this protocol does not define.
fn decodeInto(bytes: []const u8, out: *c.zval) !bool {
    const envelope = protocol.Current.decodeBorrowed(bytes, limits) catch |err| return malformed(err);
    switch (envelope.value) {
        .unknown => return false,
        .typed => |value| switch (value) {
            inline else => |payload| packet.toZval(@TypeOf(payload), payload, out) catch |err| return malformed(err),
        },
    }
    return true;
}

fn malformed(err: anyerror) exception.Error {
    return exception.throwExceptionEx(@import("../root.zig").PacketExceptionClass.entry, 0, "malformed packet: %s", .{@errorName(err).ptr});
}

/// A converted packet whose exact encoded size is known, ready to be written.
pub const Encoded = struct {
    header: protocol.packet.Header,
    value: packet.Packet,
    size: usize,

    pub fn write(self: Encoded, out: []u8) void {
        var writer = protocol.Writer.init(out[0..self.size]);
        writer.writeVarU32(self.header.toWire()) catch unreachable;
        protocol.version.encodePayload(&writer, self.value) catch unreachable;
    }
};

/// Converts `fields` with `arena` holding any lists; strings stay borrowed from PHP.
pub fn prepare(arena: std.mem.Allocator, kind: Kind, fields: *c.zval, sender: u2, target: u2, arg: u32) !Encoded {
    var encoder: packet.Encoder = .{ .arena = arena };
    const value: packet.Packet = switch (kind) {
        inline else => |tag| @unionInit(packet.Packet, @tagName(tag), encoder.convert(@FieldType(packet.Packet, @tagName(tag)), fields) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            var buffer: [512]u8 = undefined;
            return exception.argumentValueError(arg, "%s", .{encoder.describe(&buffer).ptr});
        }),
    };
    const header: protocol.packet.Header = .{ .packet_id = protocol.registry.packetId(kind).?, .sender_subclient = sender, .target_subclient = target };
    var counter: protocol.CountingWriter = .{};
    counter.writeVarU32(header.toWire()) catch unreachable;
    protocol.version.encodePayload(&counter, value) catch return exception.argumentValueError(arg, "violates a protocol bound of %s", .{@tagName(kind).ptr});
    return .{ .header = header, .value = value, .size = counter.cursor };
}

/// Encodes into a PHP string sized exactly from a counting pass.
pub fn encodeValue(kind: Kind, fields: *c.zval, sender: u2, target: u2, arg: u32) !*zend.String {
    const arena = scratch.begin();
    defer scratch.end(arena);
    const encoded = try prepare(arena.allocator(), kind, fields, sender, target, arg);
    const out = zend.String.alloc(encoded.size, false);
    encoded.write(out.mutableSlice());
    return out;
}

fn deref(zv: *c.zval) *c.zval {
    return if (Zval.raw.is(zv, .reference)) Zval.raw.asUnchecked(zv, .reference).val() else zv;
}
