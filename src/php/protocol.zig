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

    pub fn decode(bytes: []const u8, max_values: ?i64) !?*zend.Array {
        const limit = try valueLimit(max_values, 2);
        var out: c.zval = undefined;
        if (!try decodeInto(bytes, &out, limit)) return null;
        return Zval.raw.asUnchecked(&out, .array);
    }

    /// Decodes a list of packets in one call, with null for IDs this protocol does not define.
    pub fn decodeMany(packets: *zend.Array, max_values: ?i64) !*zend.Array {
        const limit = try valueLimit(max_values, 2);
        var list = zend.Array.ListBuilder.init(@intCast(packets.len()));
        var values = packets.fastValueIterator();
        while (values.next()) |raw| {
            const value = deref(raw);
            if (!Zval.raw.is(value, .string)) {
                list.finish().release();
                return exception.argumentTypeError(1, "must contain only strings", .{});
            }
            var out: c.zval = undefined;
            const known = decodeInto(Zval.raw.asUnchecked(value, .string), &out, limit) catch |err| {
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
            list.append(.str, try encodeValue(kind, pair.fields, pair.sender, pair.target, 1));
        }
        return list.finish();
    }

    /// Encodes `[packet, fields]` pairs and already encoded packets into one batch body, each behind its varint length.
    pub fn encodeBatch(packets: *zend.Array) !*zend.String {
        const arena = scratch.begin();
        defer scratch.end(arena);
        const allocator = arena.allocator();
        const items = try allocator.alloc(BatchItem, packets.len());
        var typed: std.ArrayList(u8) = .empty;
        var total: usize = 0;
        var values = packets.fastValueIterator();
        for (items) |*item| {
            const value = deref(values.next().?);
            if (Zval.raw.is(value, .string)) {
                const bytes = Zval.raw.asUnchecked(value, .string);
                if (bytes.len == 0) return exception.argumentValueError(1, "must not contain empty packets", .{});
                item.* = .{ .encoded = bytes };
            } else {
                const pair = try pairOf(value, 1);
                const start = typed.items.len;
                try append(allocator, &typed, try resolveZval(pair.ref, 1), pair.fields, pair.sender, pair.target, 1);
                item.* = .{ .typed = .{ .start = start, .end = typed.items.len } };
            }
            const size = item.bytes(typed.items).len;
            total += lengthSize(size) + size;
        }
        const out = zend.String.alloc(total, false);
        var writer = protocol.Writer.init(out.mutableSlice());
        for (items) |item| {
            const bytes = item.bytes(typed.items);
            writer.writeVarU32(@intCast(bytes.len)) catch unreachable;
            writer.writeRaw(bytes) catch unreachable;
        }
        std.debug.assert(writer.cursor == total);
        return out;
    }

    /// Lists every packet and the types reachable from them, for generating typed wrappers around this protocol.
    pub fn schema() *zend.Array {
        return @import("schema.zig").build();
    }
};

const BatchItem = union(enum) {
    encoded: []const u8,
    typed: struct { start: usize, end: usize },

    fn bytes(self: BatchItem, typed: []const u8) []const u8 {
        return switch (self) {
            .encoded => |encoded| encoded,
            .typed => |range| typed[range.start..range.end],
        };
    }
};

fn lengthSize(len: usize) usize {
    var counter: protocol.CountingWriter = .{};
    counter.writeVarU32(@intCast(len)) catch unreachable;
    return counter.cursor;
}

fn valueLimit(max_values: ?i64, arg: u32) !usize {
    const value = max_values orelse 0;
    if (value < 0) return exception.argumentValueError(arg, "must not be negative", .{});
    return if (value == 0) std.math.maxInt(usize) else @intCast(value);
}

pub const Pair = struct { ref: *c.zval, fields: *c.zval, sender: u2 = 0, target: u2 = 0 };

/// Reads `[packet, fields]`, optionally followed by the sender and target sub-client IDs.
pub fn pairOf(value: *c.zval, arg: u32) !Pair {
    if (Zval.raw.is(value, .array)) {
        const array = Zval.raw.asUnchecked(value, .array);
        const len = array.len();
        if (len >= 2 and len <= 4) {
            const ref = array.findIndex(0);
            const fields = array.findIndex(1);
            if (ref != null and fields != null) {
                var pair: Pair = .{ .ref = deref(ref.?), .fields = deref(fields.?) };
                if (len >= 3) pair.sender = try subClient(array.findIndex(2), arg);
                if (len == 4) pair.target = try subClient(array.findIndex(3), arg);
                return pair;
            }
        }
    }
    return exception.argumentTypeError(arg, "must contain [packet, fields] pairs", .{});
}

fn subClient(raw: ?*c.zval, arg: u32) !u2 {
    const value = deref(raw orelse return exception.argumentTypeError(arg, "must contain [packet, fields, sender, target] lists", .{}));
    if (!Zval.raw.is(value, .int)) return exception.argumentTypeError(arg, "must use int sub-client IDs", .{});
    return std.math.cast(u2, Zval.raw.asUnchecked(value, .int)) orelse exception.argumentValueError(arg, "must use sub-client IDs between 0 and 3", .{});
}

const kinds_by_id: [1 << 10]?Kind = blk: {
    @setEvalBranchQuota(100_000);
    var table: [1 << 10]?Kind = @splat(null);
    for (std.enums.values(Kind)) |kind| table[protocol.registry.packetId(kind).?] = kind;
    break :blk table;
};

fn kindOf(packet_id: i64) ?Kind {
    const value = std.math.cast(u10, packet_id) orelse return null;
    return kinds_by_id[value];
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
fn decodeInto(bytes: []const u8, out: *c.zval, max_values: usize) !bool {
    const envelope = protocol.Current.decodeBorrowed(bytes, limits) catch |err| return malformed(err);
    switch (envelope.value) {
        .unknown => return false,
        .typed => |value| switch (value) {
            inline else => |payload| {
                packet.limitValues(max_values);
                packet.toZval(@TypeOf(payload), payload, out) catch |err| return malformed(err);
            },
        },
    }
    return true;
}

fn malformed(err: anyerror) exception.Error {
    return exception.throwExceptionEx(@import("../root.zig").PacketExceptionClass.entry, 0, "malformed packet: %s", .{@errorName(err).ptr});
}

const spare_bytes = 512;

/// Appends a packet's header and payload to `out`, converting `fields` straight into that packet's type.
pub fn append(arena: std.mem.Allocator, out: *std.ArrayList(u8), kind: Kind, fields: *c.zval, sender: u2, target: u2, arg: u32) !void {
    switch (kind) {
        inline else => |tag| {
            var encoder: packet.Encoder = .{ .arena = arena };
            const value = encoder.convert(@FieldType(packet.Packet, @tagName(tag)), fields) catch |err| {
                if (err == error.OutOfMemory) return error.OutOfMemory;
                var buffer: [512]u8 = undefined;
                return exception.argumentValueError(arg, "%s", .{encoder.describe(&buffer).ptr});
            };
            const header: protocol.packet.Header = .{ .packet_id = comptime protocol.registry.packetId(tag).?, .sender_subclient = sender, .target_subclient = target };
            try out.ensureUnusedCapacity(arena, spare_bytes);
            var writer = protocol.Writer.init(out.unusedCapacitySlice());
            if (emit(&writer, header, &value)) {
                out.items.len += writer.cursor;
                return;
            } else |err| if (err != error.NoSpaceLeft) return boundError(arg, tag);

            var counter: protocol.CountingWriter = .{};
            emit(&counter, header, &value) catch return boundError(arg, tag);
            try out.ensureUnusedCapacity(arena, counter.cursor);
            writer = protocol.Writer.init(out.unusedCapacitySlice()[0..counter.cursor]);
            emit(&writer, header, &value) catch unreachable;
            out.items.len += writer.cursor;
        },
    }
}

fn emit(writer: anytype, header: protocol.packet.Header, value: anytype) !void {
    try writer.writeVarU32(header.toWire());
    try value.encode(writer);
}

fn boundError(arg: u32, comptime kind: Kind) exception.Error {
    return exception.argumentValueError(arg, "violates a protocol bound of %s", .{@tagName(kind).ptr});
}

pub fn encodeValue(kind: Kind, fields: *c.zval, sender: u2, target: u2, arg: u32) !*zend.String {
    const arena = scratch.begin();
    defer scratch.end(arena);
    var bytes: std.ArrayList(u8) = .empty;
    try append(arena.allocator(), &bytes, kind, fields, sender, target, arg);
    const out = zend.String.alloc(bytes.items.len, false);
    @memcpy(out.mutableSlice(), bytes.items);
    return out;
}

fn deref(zv: *c.zval) *c.zval {
    return if (Zval.raw.is(zv, .reference)) Zval.raw.asUnchecked(zv, .reference).val() else zv;
}
