//! PHP classes bound to protocol structs, which are then decoded into and encoded from objects by property slot.
const std = @import("std");
const phpz = @import("phpz");
const packet = @import("packet.zig");
const schema = @import("schema.zig");

const c = phpz.c;
const zend = phpz.zend;
const Zval = phpz.Zval;
const exception = phpz.exception;

const Packet = packet.Packet;
const Kind = packet.Kind;

const gpa = std.heap.c_allocator;

const Bindable = struct { T: type, name: [:0]const u8 };

const bindable: []const Bindable = blk: {
    @setEvalBranchQuota(100_000_000);
    var out: []const Bindable = &.{};
    for (@typeInfo(Kind).@"enum".field_names) |name| out = out ++ .{Bindable{ .T = @FieldType(Packet, name), .name = name }};
    for (schema.named) |entry| {
        if (@typeInfo(entry.T) == .@"struct") out = out ++ .{Bindable{ .T = entry.T, .name = std.fmt.comptimePrint("{s}", .{entry.name}) }};
    }
    break :blk out;
};

const names: [bindable.len][]const u8 = blk: {
    var out: [bindable.len][]const u8 = undefined;
    for (bindable, &out) |entry, *name| name.* = entry.name;
    break :blk out;
};

fn indexOf(comptime T: type) ?usize {
    @setEvalBranchQuota(1_000_000);
    for (bindable, 0..) |entry, i| if (entry.T == T) return i;
    return null;
}

fn fieldCount(comptime T: type) usize {
    return @typeInfo(T).@"struct".field_names.len;
}

const starts: [bindable.len]usize = blk: {
    @setEvalBranchQuota(1_000_000);
    var out: [bindable.len]usize = undefined;
    var next: usize = 0;
    for (bindable, &out) |entry, *start| {
        start.* = next;
        next += fieldCount(entry.T);
    }
    break :blk out;
};

const total_fields = starts[bindable.len - 1] + fieldCount(bindable[bindable.len - 1].T);

/// The struct a packet with one struct field is flattened into when its name is bound.
pub fn FlatInner(comptime T: type) ?type {
    comptime {
        const i = indexOf(T) orelse return null;
        if (i >= @typeInfo(Kind).@"enum".field_names.len) return null;
        const info = @typeInfo(T).@"struct";
        if (info.field_types.len != 1) return null;
        const F = info.field_types[0];
        if (@typeInfo(F) != .@"struct" or indexOf(F) == null) return null;
        return F;
    }
}

const Table = struct {
    classes: [bindable.len]?*c.zend_class_entry = @splat(null),
    flat: [bindable.len]bool = @splat(false),
    plain: [bindable.len]bool = @splat(false),
    offsets: [total_fields]u32 = undefined,
};

/// Classes live as long as the request that bound them, so every thread keeps its own table.
threadlocal var table: ?*Table = null;

pub const Class = struct {
    ce: *c.zend_class_entry,
    offsets: []const u32,
    /// Every property is a bound field, so new objects need no default values.
    plain: bool,

    pub fn slot(self: Class, obj: *c.zend_object, index: usize) *c.zval {
        return @ptrFromInt(@intFromPtr(obj) + self.offsets[index]);
    }
};

pub inline fn classOf(comptime T: type) ?Class {
    const i = comptime indexOf(T) orelse return null;
    const bound = table orelse return null;
    const ce = bound.classes[i] orelse return null;
    return .{ .ce = ce, .offsets = bound.offsets[starts[i]..][0..fieldCount(T)], .plain = bound.plain[i] };
}

pub inline fn isFlat(comptime T: type) bool {
    const i = comptime indexOf(T) orelse return false;
    const bound = table orelse return false;
    return bound.flat[i];
}

pub fn release() void {
    if (table) |bound| gpa.destroy(bound);
    table = null;
}

pub fn bind(types: *zend.Array) !void {
    const next = try gpa.create(Table);
    next.* = .{};
    errdefer gpa.destroy(next);

    var entries = types.iterator();
    while (entries.next()) |entry| {
        const name = switch (entry.key) {
            .string => |key| key,
            .int => return exception.argumentValueError(1, "must be keyed by schema names", .{}),
        };
        const value = deref(entry.value);
        if (!Zval.raw.is(value, .string)) return exception.argumentTypeError(1, "must map schema names to class names", .{});
        const ce = c.zend_lookup_class(Zval.raw.asUnchecked(value, .str).ptr()) orelse
            return exception.argumentValueError(1, "binds %s to an unknown class", .{name.ptr});
        const index = for (names, 0..) |candidate, i| {
            if (std.mem.eql(u8, candidate, name)) break i;
        } else return exception.argumentValueError(1, "names an unknown struct or packet %s", .{name.ptr});
        if (next.classes[index] != null) return exception.argumentValueError(1, "binds %s twice", .{name.ptr});
        next.classes[index] = ce;
    }

    for (flat_targets, 0..) |target, i| {
        const inner = target orelse continue;
        if (next.classes[i] != null and next.classes[inner] == null) {
            next.classes[inner] = next.classes[i];
            next.classes[i] = null;
            next.flat[i] = true;
        }
    }

    inline for (bindable, 0..) |entry, i| {
        if (next.classes[i]) |ce| {
            try check(entry, ce, next.offsets[starts[i]..][0..fieldCount(entry.T)], next);
            next.plain[i] = ce.default_properties_count == fieldCount(entry.T);
        }
    }

    release();
    table = next;
}

const flat_targets: [bindable.len]?usize = blk: {
    @setEvalBranchQuota(100_000_000);
    var out: [bindable.len]?usize = @splat(null);
    for (bindable, &out) |entry, *target| {
        if (FlatInner(entry.T)) |Inner| target.* = indexOf(Inner);
    }
    break :blk out;
};

const unusable_class = c.ZEND_ACC_INTERFACE | c.ZEND_ACC_TRAIT | c.ZEND_ACC_ENUM | c.ZEND_ACC_EXPLICIT_ABSTRACT_CLASS | c.ZEND_ACC_IMPLICIT_ABSTRACT_CLASS;

/// Native code writes slots without PHP's type checks, so a class only binds if every value it is given fits.
fn check(comptime entry: Bindable, ce: *c.zend_class_entry, offsets: []u32, next: *const Table) !void {
    const class_name: [*:0]const u8 = @ptrCast(ce.name.*.val());
    if (ce.ce_flags & unusable_class != 0 or ce.unnamed_1.create_object != null) {
        return exception.argumentValueError(1, "binds %s to %s, which cannot be created as a plain object", .{ entry.name.ptr, class_name });
    }
    const info = @typeInfo(entry.T).@"struct";
    inline for (info.field_names, info.field_types, 0..) |snake, F, i| {
        const field = comptime camel(snake);
        const found: ?*c.zend_property_info = @ptrCast(@alignCast(c.zend_hash_str_find_ptr(&ce.properties_info, field.ptr, field.len)));
        const property = found orelse return exception.argumentValueError(1, "binds %s to %s, which has no property %s", .{ entry.name.ptr, class_name, field.ptr });
        if (property.flags & (c.ZEND_ACC_STATIC | c.ZEND_ACC_VIRTUAL) != 0 or property.hooks != null) {
            return exception.argumentValueError(1, "binds %s to %s, whose property %s is not a plain instance property", .{ entry.name.ptr, class_name, field.ptr });
        }
        if (!accepts(F, property.type, next)) {
            return exception.argumentValueError(1, "binds %s to %s, whose property %s does not accept %s", .{ entry.name.ptr, class_name, field.ptr, comptime describe(F).ptr });
        }
        offsets[i] = property.offset;
    }
}

fn accepts(comptime F: type, t: c.zend_type, next: *const Table) bool {
    if (t.type_mask & c._ZEND_TYPE_MASK == 0) return true;
    const mask = t.type_mask & c._ZEND_TYPE_MAY_BE_MASK;
    return switch (@typeInfo(F)) {
        .void => mask & c.MAY_BE_NULL != 0,
        .bool => mask & c.MAY_BE_BOOL == c.MAY_BE_BOOL,
        .int, .@"enum" => mask & c.MAY_BE_LONG != 0,
        .float => mask & c.MAY_BE_DOUBLE != 0,
        .optional => |info| mask & c.MAY_BE_NULL != 0 and accepts(info.child, t, next),
        .pointer => |info| mask & (if (info.child == u8) c.MAY_BE_STRING else c.MAY_BE_ARRAY) != 0,
        .array => |info| mask & (if (info.child == u8) c.MAY_BE_STRING else c.MAY_BE_ARRAY) != 0,
        .@"union" => mask & c.MAY_BE_ARRAY != 0,
        .@"struct" => if (comptime isBitset(F))
            mask & c.MAY_BE_STRING != 0
        else if (comptime isList(F))
            mask & c.MAY_BE_ARRAY != 0
        else if (next.classes[comptime indexOf(F).?]) |ce|
            acceptsObject(t, ce)
        else
            mask & c.MAY_BE_ARRAY != 0,
        else => @compileError("unsupported type " ++ @typeName(F)),
    };
}

fn acceptsObject(t: c.zend_type, ce: *c.zend_class_entry) bool {
    if (t.type_mask & c.MAY_BE_OBJECT != 0) return true;
    if (t.type_mask & c._ZEND_TYPE_NAME_BIT == 0 or t.type_mask & c._ZEND_TYPE_LIST_BIT != 0) return false;
    const target = c.zend_lookup_class(@ptrCast(@alignCast(t.ptr))) orelse return false;
    return c.instanceof_function(ce, target);
}

fn camel(comptime name: []const u8) [:0]const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: [:0]const u8 = "";
        var upper = false;
        for (name) |byte| {
            if (byte == '_') {
                upper = true;
                continue;
            }
            out = out ++ .{if (upper) std.ascii.toUpper(byte) else byte};
            upper = false;
        }
        return out;
    }
}

fn describe(comptime F: type) [:0]const u8 {
    return switch (@typeInfo(F)) {
        .void => "null",
        .bool => "bool",
        .int, .@"enum" => "int",
        .float => "float",
        .optional => |info| "null and " ++ describe(info.child),
        .pointer => |info| if (info.child == u8) "string" else "array",
        .array => |info| if (info.child == u8) "string" else "array",
        .@"union" => "array",
        .@"struct" => if (isBitset(F)) "string" else if (isList(F)) "array" else "an array or its bound class",
        else => @compileError("unsupported type " ++ @typeName(F)),
    };
}

fn isList(comptime T: type) bool {
    return @hasDecl(T, "Element") and @hasDecl(T, "iterator");
}

fn isBitset(comptime T: type) bool {
    return @hasDecl(T, "isSet") and @hasDecl(T, "len");
}

fn deref(zv: *c.zval) *c.zval {
    return if (Zval.raw.is(zv, .reference)) Zval.raw.asUnchecked(zv, .reference).val() else zv;
}
