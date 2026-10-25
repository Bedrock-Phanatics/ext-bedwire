//! Describes protocol-zig's packets and types as PHP arrays, so code generators work from the same types the bridge walks.
const std = @import("std");
const phpz = @import("phpz");
const packet = @import("packet.zig");
const protocol_php = @import("protocol.zig");
const protocol = @import("native").protocol;

const c = phpz.c;
const zend = phpz.zend;
const Zval = phpz.Zval;

const Packet = packet.Packet;
const Kind = packet.Kind;

const Named = struct { T: type, name: []const u8 };

fn isList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Element") and @hasDecl(T, "iterator");
}

fn isBitset(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "isSet") and @hasDecl(T, "len");
}

fn pascal(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        var upper = true;
        for (name) |byte| {
            if (byte == '_' or byte == '.') {
                upper = true;
                continue;
            }
            out = out ++ .{if (upper) std.ascii.toUpper(byte) else byte};
            upper = false;
        }
        return out;
    }
}

/// Anonymous types are named after where they first appear, since their compiler names carry unstable counters.
fn baseName(comptime T: type, comptime hint: []const u8) []const u8 {
    @setEvalBranchQuota(1_000_000);
    const full = @typeName(T);
    if (std.mem.indexOf(u8, full, "__struct_") != null or std.mem.indexOf(u8, full, "__union_") != null or std.mem.indexOf(u8, full, "__enum_") != null) return hint;
    const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse return full;
    return full[dot + 1 ..];
}

/// The module a type is declared in, used to tell apart types sharing a name.
fn moduleName(comptime T: type) []const u8 {
    @setEvalBranchQuota(1_000_000);
    const full = @typeName(T);
    const last = std.mem.lastIndexOfScalar(u8, full, '.') orelse return "";
    const before = std.mem.lastIndexOfScalar(u8, full[0..last], '.') orelse return pascal(full[0..last]);
    return pascal(full[before + 1 .. last]);
}

const found: []const Named = blk: {
    @setEvalBranchQuota(100_000_000);
    var seen: []const Named = &.{};
    for (@typeInfo(Kind).@"enum".field_names) |name| {
        const P = @FieldType(Packet, name);
        const info = @typeInfo(P).@"struct";
        for (info.field_names, info.field_types) |field, F| visit(F, pascal(name) ++ pascal(field), &seen);
    }
    break :blk seen;
};

fn visit(comptime T: type, comptime hint: []const u8, comptime seen: *[]const Named) void {
    switch (@typeInfo(T)) {
        .optional => |info| visit(info.child, hint, seen),
        .pointer => |info| visit(info.child, hint, seen),
        .array => |info| visit(info.child, hint, seen),
        .@"enum" => _ = add(T, hint, seen),
        .@"struct" => |info| {
            if (isBitset(T)) return;
            if (isList(T)) return visit(T.Element, hint, seen);
            if (!add(T, hint, seen)) return;
            const name = seen.*[seen.len - 1].name;
            for (info.field_names, info.field_types) |field, F| visit(F, name ++ pascal(field), seen);
        },
        .@"union" => |info| {
            if (!add(T, hint, seen)) return;
            const name = seen.*[seen.len - 1].name;
            for (info.field_names, info.field_types) |variant, F| visit(F, name ++ pascal(variant), seen);
        },
        else => {},
    }
}

fn add(comptime T: type, comptime hint: []const u8, comptime seen: *[]const Named) bool {
    for (seen.*) |known| if (known.T == T) return false;
    seen.* = seen.* ++ .{Named{ .T = T, .name = baseName(T, hint) }};
    return true;
}

/// Every reachable struct, union and enum under a unique name. Types sharing a name are prefixed with their module.
const named: []const Named = blk: {
    @setEvalBranchQuota(100_000_000);
    var out: []const Named = &.{};
    for (found) |entry| {
        var shared = false;
        for (found) |other| {
            if (other.T != entry.T and std.mem.eql(u8, other.name, entry.name)) shared = true;
        }
        out = out ++ .{Named{ .T = entry.T, .name = if (shared) moduleName(entry.T) ++ entry.name else entry.name }};
    }
    for (out, 0..) |a, i| for (out[i + 1 ..]) |b| if (std.mem.eql(u8, a.name, b.name)) @compileError("schema type name " ++ a.name ++ " is not unique");
    break :blk out;
};

fn nameOf(comptime T: type) []const u8 {
    @setEvalBranchQuota(1_000_000);
    for (named) |entry| if (entry.T == T) return entry.name;
    @compileError("unnamed schema type " ++ @typeName(T));
}

fn string(value: []const u8) c.zval {
    var zv: c.zval = undefined;
    Zval.raw.set(&zv, .string, value);
    return zv;
}

fn tuple(items: []const c.zval) c.zval {
    var list = zend.Array.ListBuilder.init(@intCast(items.len));
    for (items) |item| {
        var copy = item;
        list.appendValue(&copy);
    }
    var zv: c.zval = undefined;
    Zval.raw.set(&zv, .array, list.finish());
    return zv;
}

fn int(value: i64) c.zval {
    var zv: c.zval = undefined;
    Zval.raw.set(&zv, .int, value);
    return zv;
}

/// A leaf is "bool", "int", "float", "string" or "null". Anything else is a list: ["optional", T], ["list", T],
/// ["list", T, length], ["bytes", length], ["bits", length] or ["type", name].
fn describe(comptime T: type) c.zval {
    return switch (@typeInfo(T)) {
        .void => string("null"),
        .bool => string("bool"),
        .int => string("int"),
        .float => string("float"),
        .@"enum", .@"union" => tuple(&.{ string("type"), string(comptime nameOf(T)) }),
        .optional => |info| tuple(&.{ string("optional"), describe(info.child) }),
        .pointer => |info| if (info.child == u8) string("string") else tuple(&.{ string("list"), describe(info.child) }),
        .array => |info| if (info.child == u8)
            tuple(&.{ string("bytes"), int(info.len) })
        else
            tuple(&.{ string("list"), describe(info.child), int(info.len) }),
        .@"struct" => if (comptime isBitset(T))
            tuple(&.{ string("bits"), int(T.len) })
        else if (comptime isList(T))
            tuple(&.{ string("list"), describe(T.Element) })
        else
            tuple(&.{ string("type"), string(comptime nameOf(T)) }),
        else => @compileError("unsupported " ++ @typeName(T)),
    };
}

fn boolean(value: bool) c.zval {
    var zv: c.zval = undefined;
    Zval.raw.set(&zv, .bool, value);
    return zv;
}

fn put(array: *zend.Array, key: []const u8, value: c.zval) void {
    var copy = value;
    _ = array.update(key, &copy);
}

/// Adds "fields" and "omittable", the fields encode() lets callers leave out because they are optional or have defaults.
fn putStruct(entry: *zend.Array, comptime T: type) void {
    const info = @typeInfo(T).@"struct";
    const fields = zend.Array.init(info.field_names.len);
    var omittable = zend.Array.ListBuilder.init(0);
    inline for (info.field_names, info.field_types, info.field_attrs) |name, F, attrs| {
        put(fields, name, describe(F));
        if (@typeInfo(F) == .optional or attrs.default_value_ptr != null) {
            var key = string(name);
            omittable.appendValue(&key);
        }
    }
    var zv: c.zval = undefined;
    Zval.raw.set(&zv, .array, fields);
    put(entry, "fields", zv);
    Zval.raw.set(&zv, .array, omittable.finish());
    put(entry, "omittable", zv);
}

pub fn build() *zend.Array {
    @setEvalBranchQuota(100_000_000);
    const root = zend.Array.init(4);
    put(root, "protocol", int(protocol.protocol_version));
    put(root, "minecraft", string(protocol.minecraft_version));

    const packets = zend.Array.init(@typeInfo(Kind).@"enum".field_names.len);
    inline for (@typeInfo(Kind).@"enum".field_names) |name| {
        const kind = @field(Kind, name);
        const entry = zend.Array.init(4);
        put(entry, "id", int(protocol.registry.packetId(kind).?));
        put(entry, "direction", int(@backingInt(protocol_php.directionOf(kind))));
        putStruct(entry, @FieldType(Packet, name));
        var zv: c.zval = undefined;
        Zval.raw.set(&zv, .array, entry);
        put(packets, name, zv);
    }
    var zv: c.zval = undefined;
    Zval.raw.set(&zv, .array, packets);
    put(root, "packets", zv);

    const types = zend.Array.init(named.len);
    inline for (named) |entry_info| {
        const T = entry_info.T;
        const entry = zend.Array.init(4);
        switch (@typeInfo(T)) {
            .@"struct" => {
                put(entry, "kind", string("struct"));
                putStruct(entry, T);
            },
            .@"union" => |info| {
                put(entry, "kind", string("union"));
                const variants = zend.Array.init(info.field_names.len);
                inline for (info.field_names, info.field_types) |variant, F| put(variants, variant, describe(F));
                var field: c.zval = undefined;
                Zval.raw.set(&field, .array, variants);
                put(entry, "variants", field);
            },
            .@"enum" => |info| {
                put(entry, "kind", string("enum"));
                const values = zend.Array.init(info.field_names.len);
                inline for (info.field_names, info.field_values) |value_name, value| {
                    var item = int(value);
                    _ = values.symtableUpdate(value_name, &item);
                }
                var field: c.zval = undefined;
                Zval.raw.set(&field, .array, values);
                put(entry, "values", field);
                put(entry, "open", boolean(info.mode == .nonexhaustive));
            },
            else => unreachable,
        }
        Zval.raw.set(&zv, .array, entry);
        put(types, entry_info.name, zv);
    }
    Zval.raw.set(&zv, .array, types);
    put(root, "types", zv);
    return root;
}
