//! Converts protocol-zig packets to PHP arrays and back, derived at comptime from the packet types.
const std = @import("std");
const phpz = @import("phpz");
const protocol = @import("native").protocol;

const c = phpz.c;
const zend = phpz.zend;
const Zval = phpz.Zval;

pub const Packet = protocol.typed.Packet;
pub const Kind = protocol.PacketKind;

fn isList(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "Element") and @hasDecl(T, "iterator");
}

fn isBitset(comptime T: type) bool {
    return @typeInfo(T) == .@"struct" and @hasDecl(T, "isSet") and @hasDecl(T, "len");
}

/// Every struct and union reachable from a packet, each of which gets interned key strings.
const keyed_types: []const type = blk: {
    @setEvalBranchQuota(10_000_000);
    var seen: []const type = &.{};
    collect(Packet, &seen);
    break :blk seen;
};

fn collect(comptime T: type, comptime seen: *[]const type) void {
    switch (@typeInfo(T)) {
        .optional => |info| collect(info.child, seen),
        .pointer => |info| collect(info.child, seen),
        .array => |info| collect(info.child, seen),
        .@"struct" => |info| {
            if (isBitset(T)) return;
            if (isList(T)) return collect(T.Element, seen);
            for (seen.*) |known| if (known == T) return;
            seen.* = seen.* ++ .{T};
            for (info.field_types) |F| collect(F, seen);
        },
        .@"union" => |info| {
            for (seen.*) |known| if (known == T) return;
            seen.* = seen.* ++ .{T};
            for (info.field_types) |F| collect(F, seen);
        },
        else => {},
    }
}

fn fieldNames(comptime T: type) []const [:0]const u8 {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| info.field_names,
        .@"union" => |info| info.field_names,
        else => unreachable,
    };
}

fn fieldIndex(comptime names: []const [:0]const u8, comptime name: []const u8) usize {
    @setEvalBranchQuota(100_000);
    for (names, 0..) |candidate, i| if (std.mem.eql(u8, candidate, name)) return i;
    unreachable;
}

fn Keys(comptime T: type) type {
    return struct {
        var strings: [fieldNames(T).len]*c.zend_string = undefined;
    };
}

/// Interns every field and tag name once, at module startup, so arrays are built without hashing new keys.
pub fn intern() void {
    @setEvalBranchQuota(10_000_000);
    inline for (keyed_types) |T| {
        for (fieldNames(T), &Keys(T).strings) |name, *slot| slot.* = c.zend_string_init_interned.?(name.ptr, name.len, true);
    }
}

pub fn kindName(kind: Kind) *c.zend_string {
    return Keys(Packet).strings[@backingInt(kind)];
}

pub fn kindByName(name: []const u8) ?Kind {
    return std.meta.stringToEnum(Kind, name);
}

pub const DecodeError = protocol.DecodeError || error{TooManyValues};

/// PHP values the current conversion may still create, so a small packet cannot expand into a huge array tree.
threadlocal var remaining: usize = std.math.maxInt(usize);

pub fn limitValues(max: usize) void {
    remaining = max;
}

fn spend(count: usize) DecodeError!void {
    if (count > remaining) return error.TooManyValues;
    remaining -= count;
}

/// Writes `value` into the uninitialized `out`, which is left untouched on error.
pub fn toZval(comptime T: type, value: T, out: *c.zval) DecodeError!void {
    switch (@typeInfo(T)) {
        .void => Zval.raw.set(out, .null, {}),
        .bool => Zval.raw.set(out, .bool, value),
        .int => |info| {
            if (info.bits > 64) @compileError("unsupported integer " ++ @typeName(T));
            const wide: i64 = if (info.bits == 64 and info.signedness == .unsigned) @bitCast(value) else value;
            Zval.raw.set(out, .int, wide);
        },
        .float => Zval.raw.set(out, .float, value),
        .@"enum" => Zval.raw.set(out, .int, @backingInt(value)),
        .optional => |info| if (value) |inner| try toZval(info.child, inner, out) else Zval.raw.set(out, .null, {}),
        .pointer => |info| {
            if (info.size != .slice) @compileError("unsupported pointer " ++ @typeName(T));
            if (info.child == u8) return Zval.raw.set(out, .string, value);
            try spend(value.len);
            var list = zend.Array.ListBuilder.init(@intCast(value.len));
            for (value) |item| try appendTo(info.child, item, &list);
            Zval.raw.set(out, .array, list.finish());
        },
        .array => |info| {
            if (info.child == u8) return Zval.raw.set(out, .string, &value);
            try spend(info.len);
            var list = zend.Array.ListBuilder.init(info.len);
            for (value) |item| try appendTo(info.child, item, &list);
            Zval.raw.set(out, .array, list.finish());
        },
        .@"struct" => |info| {
            if (comptime isBitset(T)) return Zval.raw.set(out, .str, bitsetBytes(T, value));
            if (comptime isList(T)) {
                try spend(value.len);
                var list = zend.Array.ListBuilder.init(@intCast(value.len));
                var items = value.iterator();
                while (items.next() catch |err| return discard(&list, err)) |item| try appendTo(T.Element, item, &list);
                return Zval.raw.set(out, .array, list.finish());
            }
            try spend(info.field_names.len);
            const array = zend.Array.init(info.field_names.len);
            errdefer array.release();
            inline for (info.field_names, info.field_types, 0..) |name, F, i| {
                var field: c.zval = undefined;
                try toZval(F, @field(value, name), &field);
                _ = c.zend_hash_add_new(array.ptr(), Keys(T).strings[i], &field);
            }
            Zval.raw.set(out, .array, array);
        },
        .@"union" => |info| switch (value) {
            inline else => |payload, tag| {
                const index = comptime fieldIndex(info.field_names, @tagName(tag));
                try spend(1);
                const array = zend.Array.init(1);
                errdefer array.release();
                var field: c.zval = undefined;
                try toZval(@TypeOf(payload), payload, &field);
                _ = c.zend_hash_add_new(array.ptr(), Keys(T).strings[index], &field);
                Zval.raw.set(out, .array, array);
            },
        },
        else => @compileError("unsupported type " ++ @typeName(T)),
    }
}

fn appendTo(comptime T: type, value: T, list: *zend.Array.ListBuilder) DecodeError!void {
    var item: c.zval = undefined;
    toZval(T, value, &item) catch |err| return discard(list, err);
    list.appendValue(&item);
}

fn discard(list: *zend.Array.ListBuilder, err: DecodeError) DecodeError {
    list.finish().release();
    return err;
}

fn bitsetBytes(comptime T: type, value: T) *zend.String {
    const len = (T.len + 7) / 8;
    const out = zend.String.alloc(len, false);
    const bytes = out.mutableSlice();
    for (bytes[0..len], 0..) |*byte, i| byte.* = @truncate(value.value >> @intCast(i * 8));
    return out;
}

pub const Segment = union(enum) { name: []const u8, index: usize };

/// Converts PHP values into packet fields; strings and arrays are borrowed from PHP for the call.
pub const Encoder = struct {
    arena: std.mem.Allocator,
    path: [max_path]Segment = undefined,
    depth: usize = 0,
    problem: Problem = .{ .reason = "is invalid" },

    const max_path = 24;

    pub const Problem = struct { reason: [:0]const u8, given: ?*c.zval = null };
    pub const Error = error{ Invalid, OutOfMemory };

    fn push(self: *Encoder, segment: Segment) void {
        if (self.depth < max_path) self.path[self.depth] = segment;
        self.depth += 1;
    }

    fn pop(self: *Encoder) void {
        self.depth -= 1;
    }

    fn fail(self: *Encoder, reason: [:0]const u8, given: ?*c.zval) Error {
        @branchHint(.cold);
        self.problem = .{ .reason = reason, .given = given };
        return error.Invalid;
    }

    /// Renders the failing field path and reason into `buffer`.
    pub fn describe(self: *const Encoder, buffer: []u8) [:0]const u8 {
        var writer = std.Io.Writer.fixed(buffer[0 .. buffer.len - 1]);
        for (self.path[0..@min(self.depth, max_path)], 0..) |segment, i| switch (segment) {
            .name => |name| writer.print("{s}{s}", .{ if (i == 0) "" else ".", name }) catch break,
            .index => |index| writer.print("[{d}]", .{index}) catch break,
        };
        if (self.depth == 0) writer.writeAll("value") catch {};
        writer.print(" {s}", .{self.problem.reason}) catch {};
        if (self.problem.given) |given| writer.print(", {s} given", .{std.mem.span(Zval.raw.getTypeName(given))}) catch {};
        const len = writer.end;
        buffer[len] = 0;
        return buffer[0..len :0];
    }

    pub fn convert(self: *Encoder, comptime T: type, raw: *c.zval) Error!T {
        const zv = deref(raw);
        switch (@typeInfo(T)) {
            .void => return {},
            .bool => {
                if (!Zval.raw.is(zv, .bool)) return self.fail("must be of type bool", zv);
                return Zval.raw.asUnchecked(zv, .bool);
            },
            .int => |info| {
                if (!Zval.raw.is(zv, .int)) return self.fail("must be of type int", zv);
                const value = Zval.raw.asUnchecked(zv, .int);
                if (info.bits == 64 and info.signedness == .unsigned) return @bitCast(value);
                return std.math.cast(T, value) orelse self.fail("is out of range for " ++ @typeName(T), null);
            },
            .float => {
                if (Zval.raw.is(zv, .float)) return @floatCast(Zval.raw.asUnchecked(zv, .float));
                if (Zval.raw.is(zv, .int)) return @floatFromInt(Zval.raw.asUnchecked(zv, .int));
                return self.fail("must be of type float", zv);
            },
            .@"enum" => |info| {
                if (!Zval.raw.is(zv, .int)) return self.fail("must be of type int", zv);
                const value = Zval.raw.asUnchecked(zv, .int);
                if (info.mode == .exhaustive) return std.enums.fromInt(T, value) orelse self.fail("is not a valid value", null);
                const tag = std.math.cast(info.tag_type, value) orelse return self.fail("is out of range for " ++ @typeName(info.tag_type), null);
                return @fromBackingInt(tag);
            },
            .optional => |info| {
                if (Zval.raw.is(zv, .null)) return null;
                return try self.convert(info.child, zv);
            },
            .pointer => |info| {
                if (info.size != .slice) @compileError("unsupported pointer " ++ @typeName(T));
                if (info.child == u8) {
                    if (!Zval.raw.is(zv, .string)) return self.fail("must be of type string", zv);
                    return Zval.raw.asUnchecked(zv, .string);
                }
                return self.items(info.child, zv);
            },
            .array => |info| {
                if (info.child == u8) {
                    if (!Zval.raw.is(zv, .string)) return self.fail("must be of type string", zv);
                    const bytes = Zval.raw.asUnchecked(zv, .string);
                    if (bytes.len != info.len) return self.fail(std.fmt.comptimePrint("must be exactly {d} bytes", .{info.len}), null);
                    return bytes[0..info.len].*;
                }
                const values = try self.items(info.child, zv);
                if (values.len != info.len) return self.fail(std.fmt.comptimePrint("must have exactly {d} elements", .{info.len}), null);
                return values[0..info.len].*;
            },
            .@"struct" => |info| {
                if (comptime isBitset(T)) return self.bitset(T, zv);
                if (comptime isList(T)) return T.init(try self.items(T.Element, zv));
                if (!Zval.raw.is(zv, .array)) return self.fail("must be of type array", zv);
                const table = Zval.raw.asUnchecked(zv, .array).ptr();
                var result: T = undefined;
                var found: u32 = 0;
                inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, F, attrs, i| {
                    self.push(.{ .name = name });
                    if (c.zend_hash_find_known_hash(table, Keys(T).strings[i])) |field| {
                        found += 1;
                        @field(result, name) = try self.convert(F, field);
                    } else if (@typeInfo(F) == .optional) {
                        @field(result, name) = null;
                    } else if (comptime attrs.defaultValue(F)) |default| {
                        @field(result, name) = default;
                    } else return self.fail("is missing", null);
                    self.pop();
                }
                if (found != c.zend_hash_num_elements(table)) return self.unknownKey(table, info.field_names);
                return result;
            },
            .@"union" => |info| {
                if (!Zval.raw.is(zv, .array)) return self.fail("must be of type array", zv);
                const array = Zval.raw.asUnchecked(zv, .array);
                if (array.len() != 1) return self.fail("must hold exactly one variant", null);
                var entries = array.iterator();
                const entry = entries.next().?;
                const key = switch (entry.key) {
                    .string => |key| key,
                    .int => return self.fail("must be keyed by a variant name", null),
                };
                inline for (info.field_names, info.field_types) |name, F| {
                    if (std.mem.eql(u8, key, name)) {
                        self.push(.{ .name = name });
                        const payload = try self.convert(F, entry.value);
                        self.pop();
                        return @unionInit(T, name, payload);
                    }
                }
                return self.fail("has an unknown variant", null);
            },
            else => @compileError("unsupported type " ++ @typeName(T)),
        }
    }

    fn items(self: *Encoder, comptime T: type, zv: *c.zval) Error![]const T {
        if (!Zval.raw.is(zv, .array)) return self.fail("must be of type array", zv);
        const array = Zval.raw.asUnchecked(zv, .array);
        const out = try self.arena.alloc(T, array.len());
        var values = array.fastValueIterator();
        var i: usize = 0;
        while (values.next()) |value| : (i += 1) {
            self.push(.{ .index = i });
            out[i] = try self.convert(T, value);
            self.pop();
        }
        return out;
    }

    fn bitset(self: *Encoder, comptime T: type, zv: *c.zval) Error!T {
        const len = (T.len + 7) / 8;
        if (!Zval.raw.is(zv, .string)) return self.fail("must be of type string", zv);
        const bytes = Zval.raw.asUnchecked(zv, .string);
        if (bytes.len != len) return self.fail(std.fmt.comptimePrint("must be exactly {d} bytes", .{len}), null);
        const Wide = @Int(.unsigned, len * 8);
        var wide: Wide = 0;
        for (bytes, 0..) |byte, i| wide |= @as(Wide, byte) << @intCast(i * 8);
        if (wide >> T.len != 0) return self.fail(std.fmt.comptimePrint("sets bits past {d}", .{T.len}), null);
        return .{ .value = @intCast(wide) };
    }

    fn unknownKey(self: *Encoder, table: *c.HashTable, comptime names: []const [:0]const u8) Error {
        var keys = zend.Array.from(table).iterator();
        while (keys.next()) |entry| {
            const key = switch (entry.key) {
                .string => |key| key,
                .int => return self.fail("has an integer key", null),
            };
            for (names) |name| {
                if (std.mem.eql(u8, key, name)) break;
            } else {
                self.push(.{ .name = key });
                return self.fail("is not a field", null);
            }
        }
        return self.fail("has unknown keys", null);
    }
};

fn deref(zv: *c.zval) *c.zval {
    return if (Zval.raw.is(zv, .reference)) Zval.raw.asUnchecked(zv, .reference).val() else zv;
}
