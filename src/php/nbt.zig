//! Reads and writes pocketmine/nbt tag trees in one native call per document.
const std = @import("std");
const phpz = @import("phpz");
const nbt = @import("nbt");
const native = @import("native");
const scratch = @import("scratch.zig");

const c = phpz.c;
const zend = phpz.zend;
const Zval = phpz.Zval;
const errors = phpz.errors;
const Format = native.nbt.Format;
const TagType = nbt.TagType;

const namespace = "pocketmine\\nbt\\";
const tag_classes = [_][:0]const u8{
    "",
    namespace ++ "tag\\ByteTag",
    namespace ++ "tag\\ShortTag",
    namespace ++ "tag\\IntTag",
    namespace ++ "tag\\LongTag",
    namespace ++ "tag\\FloatTag",
    namespace ++ "tag\\DoubleTag",
    namespace ++ "tag\\ByteArrayTag",
    namespace ++ "tag\\StringTag",
    namespace ++ "tag\\ListTag",
    namespace ++ "tag\\CompoundTag",
    namespace ++ "tag\\IntArrayTag",
};

const Slot = struct { entry: *zend.ClassEntry, offset: u32 };

/// Class entries and property offsets, resolved once per call since user classes can change between requests.
const Classes = struct {
    tags: [tag_classes.len]?Slot = @splat(null),
    list_type: u32 = 0,
    root: ?struct { entry: *zend.ClassEntry, root: u32, name: u32 } = null,

    fn tag(self: *Classes, tag_type: TagType) !Slot {
        const index = @backingInt(tag_type);
        if (index == 0 or index >= tag_classes.len) return fail("unsupported tag type %d", .{@as(c_int, index)});
        if (self.tags[index]) |slot| return slot;
        const entry = try lookup(tag_classes[index]);
        const slot: Slot = .{ .entry = entry, .offset = try offset(entry, "value") };
        if (tag_type == .list) self.list_type = try offset(entry, "tagType");
        self.tags[index] = slot;
        return slot;
    }

    fn treeRoot(self: *Classes) !@typeInfo(@FieldType(Classes, "root")).optional.child {
        if (self.root) |root| return root;
        const entry = try lookup(namespace ++ "TreeRoot");
        self.root = .{ .entry = entry, .root = try offset(entry, "root"), .name = try offset(entry, "name") };
        return self.root.?;
    }

    /// Tag classes are final, so an exact class match identifies the tag type.
    fn typeOf(self: *Classes, entry: *zend.ClassEntry) !TagType {
        for (1..tag_classes.len) |index| {
            const tag_type: TagType = @fromBackingInt(@as(u8, @intCast(index)));
            if ((try self.tag(tag_type)).entry == entry) return tag_type;
        }
        return fail("%s is not a pocketmine/nbt tag", .{entry.name().ptr});
    }
};

fn lookup(name: [:0]const u8) !*zend.ClassEntry {
    return try zend.ClassEntry.lookup(name, true) orelse fail("class %s is not available", .{name.ptr});
}

fn offset(entry: *zend.ClassEntry, comptime property: []const u8) !u32 {
    const info = entry.findPropertyInfo(property) orelse return fail("%s has no $" ++ property ++ " property", .{entry.name().ptr});
    return info.offset();
}

fn slotOf(object: *c.zend_object, at: u32) *c.zval {
    return @ptrFromInt(@intFromPtr(object) + at);
}

fn fail(comptime format: [:0]const u8, args: anytype) errors.Exception {
    return errors.throwExceptionEx(@import("../root.zig").NbtExceptionClass.entry, 0, format, args);
}

fn invalid(err: anyerror) errors.Exception {
    if (err == error.OutOfMemory) return fail("out of memory", .{});
    return fail("invalid NBT: %s", .{@errorName(err).ptr});
}

fn parseFormat(value: i64, arg: u32) !Format {
    return std.enums.fromInt(Format, value) orelse errors.argumentValueError(arg, "must be a Bedwire\\Nbt format", .{});
}

fn parseDepth(value: ?i64, arg: u32) !usize {
    const depth = std.math.cast(u32, value orelse 0) orelse return errors.argumentValueError(arg, "must not be negative", .{});
    return native.nbt.depthFromPocketMine(depth);
}

fn parseOffset(data: []const u8, value: ?i64, arg: u32) !usize {
    const start = std.math.cast(usize, value orelse 0) orelse return errors.argumentValueError(arg, "must not be negative", .{});
    if (start > data.len) return errors.argumentValueError(arg, "is past the end of the data", .{});
    return start;
}

const Reader = struct {
    classes: Classes = .{},
    unsigned_int_arrays: bool,

    fn tagObject(self: *Reader, tag: *const nbt.Tag, out: *c.zval) !void {
        const tag_type = tag.tagType();
        const slot = try self.classes.tag(tag_type);
        var object: c.zval = undefined;
        if (c.object_init_ex(&object, slot.entry.ptr()) != c.SUCCESS) return error.PhpException;
        errdefer Zval.raw.release(&object);
        const instance = Zval.raw.asUnchecked(&object, .object).ptr();

        var value: c.zval = undefined;
        switch (tag.*) {
            .end, .long_array => return fail("unsupported tag type %d", .{@as(c_int, @backingInt(tag_type))}),
            inline .byte, .short, .int, .long => |number| Zval.raw.set(&value, .int, number),
            inline .float, .double => |number| Zval.raw.set(&value, .float, number),
            .string, .byte_array => |bytes| Zval.raw.set(&value, .string, bytes),
            .int_array => |numbers| {
                var list = zend.Array.ListBuilder.init(@intCast(numbers.len));
                // PocketMine unpacks fixed-width int arrays as unsigned.
                for (numbers) |number| list.appendAssumeCapacity(.int, if (self.unsigned_int_arrays) @as(u32, @bitCast(number)) else number);
                Zval.raw.set(&value, .array, list.finish());
            },
            .list => |list| {
                var items = zend.Array.ListBuilder.init(@intCast(list.items.len));
                for (list.items) |*item| {
                    var child: c.zval = undefined;
                    self.tagObject(item, &child) catch |err| {
                        items.finish().release();
                        return err;
                    };
                    items.appendValue(&child);
                }
                Zval.raw.set(&value, .array, items.finish());
                replace(slotOf(instance, self.classes.list_type), Zval.raw.init(.int, @backingInt(list.element_type)));
            },
            .compound => |compound| {
                const array = zend.Array.init(@intCast(compound.entries.len));
                for (compound.entries) |*entry| {
                    var child: c.zval = undefined;
                    self.tagObject(&entry.value, &child) catch |err| {
                        array.release();
                        return err;
                    };
                    _ = array.symtableUpdate(entry.name, &child);
                }
                Zval.raw.set(&value, .array, array);
            },
        }
        replace(slotOf(instance, slot.offset), value);
        out.* = object;
    }

    fn treeRoot(self: *Reader, document: *const nbt.Document, out: *c.zval) !void {
        const root = try self.classes.treeRoot();
        var tag: c.zval = undefined;
        try self.tagObject(&document.root, &tag);
        var object: c.zval = undefined;
        if (c.object_init_ex(&object, root.entry.ptr()) != c.SUCCESS) {
            Zval.raw.release(&tag);
            return error.PhpException;
        }
        const instance = Zval.raw.asUnchecked(&object, .object).ptr();
        replace(slotOf(instance, root.root), tag);
        replace(slotOf(instance, root.name), Zval.raw.init(.string, document.name));
        out.* = object;
    }
};

fn replace(slot: *c.zval, value: c.zval) void {
    Zval.raw.release(slot);
    slot.* = value;
}

const Writer = struct {
    classes: Classes = .{},
    arena: std.mem.Allocator,

    const max_nesting = native.nbt.max_depth;

    fn tagOf(self: *Writer, raw: *c.zval, depth: usize) !nbt.Tag {
        const zv = deref(raw);
        if (!Zval.raw.is(zv, .object)) return fail("expected a pocketmine/nbt tag, got %s", .{Zval.raw.getTypeName(zv)});
        if (depth > max_nesting) return fail("tags nest deeper than %d levels", .{@as(c_int, max_nesting)});
        const instance = Zval.raw.asUnchecked(zv, .object).ptr();
        const tag_type = try self.classes.typeOf(zend.ClassEntry.from(instance.ce));
        const value = deref(slotOf(instance, (try self.classes.tag(tag_type)).offset));

        return switch (tag_type) {
            .byte => .{ .byte = try self.int(i8, value) },
            .short => .{ .short = try self.int(i16, value) },
            .int => .{ .int = try self.int(i32, value) },
            .long => .{ .long = try self.int(i64, value) },
            .float => .{ .float = @floatCast(try float(value)) },
            .double => .{ .double = try float(value) },
            .string => .{ .string = try stringOf(value) },
            .byte_array => .{ .byte_array = try stringOf(value) },
            .int_array => blk: {
                const array = try arrayOf(value);
                const numbers = try self.arena.alloc(i32, array.len());
                var values = array.fastValueIterator();
                for (numbers) |*number| {
                    const item = deref(values.next().?);
                    if (!Zval.raw.is(item, .int)) return fail("IntArrayTag holds a non-int value", .{});
                    number.* = @truncate(Zval.raw.asUnchecked(item, .int));
                }
                break :blk .{ .int_array = numbers };
            },
            .list => blk: {
                const array = try arrayOf(value);
                const element = deref(slotOf(instance, self.classes.list_type));
                if (!Zval.raw.is(element, .int)) return fail("ListTag has an invalid tag type", .{});
                const element_type = TagType.fromByte(std.math.cast(u8, Zval.raw.asUnchecked(element, .int)) orelse 0xff) catch return fail("ListTag has an invalid tag type", .{});
                const items = try self.arena.alloc(nbt.Tag, array.len());
                var values = array.fastValueIterator();
                for (items) |*item| item.* = try self.tagOf(values.next().?, depth + 1);
                break :blk .{ .list = .{ .element_type = element_type, .items = items } };
            },
            .compound => blk: {
                const array = try arrayOf(value);
                const entries = try self.arena.alloc(nbt.Entry, array.len());
                var iterator = array.fastIterator();
                for (entries) |*entry| {
                    const item = iterator.next().?;
                    entry.* = .{
                        .name = switch (item.key) {
                            .string => |name| @constCast(name),
                            .int => |index| try std.fmt.allocPrint(self.arena, "{d}", .{index}),
                        },
                        .value = try self.tagOf(item.value, depth + 1),
                    };
                }
                break :blk .{ .compound = .{ .entries = entries } };
            },
            .end, .long_array => unreachable,
        };
    }

    fn root(self: *Writer, raw: *c.zval) !nbt.Document {
        const zv = deref(raw);
        const tree = try self.classes.treeRoot();
        if (!Zval.raw.is(zv, .object) or Zval.raw.asUnchecked(zv, .object).ptr().ce != tree.entry.ptr()) {
            return fail("expected a pocketmine\\nbt\\TreeRoot", .{});
        }
        const instance = Zval.raw.asUnchecked(zv, .object).ptr();
        return .{
            .name = try stringOf(deref(slotOf(instance, tree.name))),
            .root = try self.tagOf(slotOf(instance, tree.root), 1),
        };
    }

    fn int(_: *Writer, comptime T: type, value: *c.zval) !T {
        if (!Zval.raw.is(value, .int)) return fail("integer tag holds a non-int value", .{});
        return std.math.cast(T, Zval.raw.asUnchecked(value, .int)) orelse fail("integer tag value is out of range", .{});
    }
};

fn float(value: *c.zval) !f64 {
    if (Zval.raw.is(value, .float)) return Zval.raw.asUnchecked(value, .float);
    if (Zval.raw.is(value, .int)) return @floatFromInt(Zval.raw.asUnchecked(value, .int));
    return fail("float tag holds a non-float value", .{});
}

fn stringOf(value: *c.zval) ![]u8 {
    if (!Zval.raw.is(value, .string)) return fail("string tag holds a non-string value", .{});
    // Encoding only reads tag bytes, so borrowing PHP's string is safe for the call.
    return @constCast(Zval.raw.asUnchecked(value, .string));
}

fn arrayOf(value: *c.zval) !*zend.Array {
    if (!Zval.raw.is(value, .array)) return fail("container tag holds a non-array value", .{});
    return Zval.raw.asUnchecked(value, .array);
}

fn deref(zv: *c.zval) *c.zval {
    return if (Zval.raw.is(zv, .reference)) Zval.raw.asUnchecked(zv, .reference).val() else zv;
}

fn objectResult(value: *c.zval) *zend.Object {
    return Zval.raw.asUnchecked(value, .object);
}

/// Writes straight into a PHP string of the exact encoded size.
fn render(arena: std.mem.Allocator, documents: []const nbt.Document, opts: nbt.Options) !*zend.String {
    var total: usize = 0;
    for (documents) |document| total += nbt.encodedLength(document, opts) catch |err| return invalid(err);
    const out = zend.String.alloc(total, false);
    errdefer out.release();
    var writer: std.Io.Writer = .fixed(out.mutableSlice()[0..total]);
    for (documents) |document| nbt.writeDocument(arena, &writer, document, opts) catch |err| return invalid(err);
    return out;
}

pub const Nbt = struct {
    pub fn __construct() !void {
        return errors.throwError(null, "Bedwire\\Nbt cannot be instantiated", .{});
    }

    pub fn transcode(data: []const u8, from: i64, to: i64, max_depth: ?i64) !*zend.String {
        const source = try parseFormat(from, 2);
        const target = try parseFormat(to, 3);
        const depth = try parseDepth(max_depth, 4);
        const arena = scratch.begin();
        defer scratch.end(arena);
        const out = native.nbt.transcode(arena.allocator(), data, source, target, depth) catch |err| return invalid(err);
        return zend.String.init(out, false);
    }

    /// Validates one document without building it and returns the bytes it spans from `offset`.
    pub fn length(data: []const u8, format: i64, start: ?i64, max_depth: ?i64) !i64 {
        const opts = native.nbt.options(try parseFormat(format, 2), try parseDepth(max_depth, 4));
        const from = try parseOffset(data, start, 3);
        return @intCast(nbt.scanDocument(data[from..], opts) catch |err| return invalid(err));
    }

    pub fn read(data: []const u8, format: i64, start: ?i64, max_depth: ?i64) !*zend.Object {
        var out: c.zval = undefined;
        _ = try readInto(data, format, start, max_depth, &out);
        return objectResult(&out);
    }

    /// Like read, and also returns the offset just past the document: `[TreeRoot, int]`.
    pub fn readAt(data: []const u8, format: i64, start: ?i64, max_depth: ?i64) !*zend.Array {
        var root: c.zval = undefined;
        const end = try readInto(data, format, start, max_depth, &root);
        var list = zend.Array.ListBuilder.init(2);
        list.appendValue(&root);
        list.appendAssumeCapacity(.int, @intCast(end));
        return list.finish();
    }

    pub fn readHeadless(data: []const u8, format: i64, tag_type: i64, start: ?i64, max_depth: ?i64) !*zend.Object {
        const fmt = try parseFormat(format, 2);
        const kind = TagType.fromByte(std.math.cast(u8, tag_type) orelse 0xff) catch return errors.argumentValueError(3, "must be a tag type", .{});
        const from = try parseOffset(data, start, 4);
        const arena = scratch.begin();
        defer scratch.end(arena);
        const parsed = nbt.parsePayload(arena.allocator(), data[from..], kind, native.nbt.options(fmt, try parseDepth(max_depth, 5))) catch |err| return invalid(err);
        var reader: Reader = .{ .unsigned_int_arrays = fmt != .network };
        var out: c.zval = undefined;
        try reader.tagObject(&parsed.tag, &out);
        return objectResult(&out);
    }

    pub fn readMultiple(data: []const u8, format: i64, max_depth: ?i64) !*zend.Array {
        const fmt = try parseFormat(format, 2);
        const opts = native.nbt.options(fmt, try parseDepth(max_depth, 3));
        const arena = scratch.begin();
        defer scratch.end(arena);
        var reader: Reader = .{ .unsigned_int_arrays = fmt != .network };
        var list = zend.Array.ListBuilder.init(1);
        errdefer list.finish().release();
        var from: usize = 0;
        while (from < data.len) {
            const parsed = nbt.parsePrefix(arena.allocator(), data[from..], opts) catch |err| return invalid(err);
            var root: c.zval = undefined;
            try reader.treeRoot(&parsed.document, &root);
            list.appendValue(&root);
            from += parsed.len;
        }
        return list.finish();
    }

    pub fn write(root: *zend.Object, format: i64) !*zend.String {
        const opts = native.nbt.options(try parseFormat(format, 2), native.nbt.max_depth);
        const arena = scratch.begin();
        defer scratch.end(arena);
        var writer: Writer = .{ .arena = arena.allocator() };
        var zv = Zval.raw.init(.object, root);
        const document = try writer.root(&zv);
        return render(arena.allocator(), &.{document}, opts);
    }

    pub fn writeHeadless(tag: *zend.Object, format: i64) !*zend.String {
        const opts = native.nbt.options(try parseFormat(format, 2), native.nbt.max_depth);
        const arena = scratch.begin();
        defer scratch.end(arena);
        var writer: Writer = .{ .arena = arena.allocator() };
        var zv = Zval.raw.init(.object, tag);
        const value = try writer.tagOf(&zv, 1);
        const len = nbt.encodedLength(value, opts) catch |err| return invalid(err);
        const out = zend.String.alloc(len, false);
        errdefer out.release();
        var output: std.Io.Writer = .fixed(out.mutableSlice()[0..len]);
        nbt.writePayload(arena.allocator(), &output, value, opts) catch |err| return invalid(err);
        return out;
    }

    pub fn writeMultiple(roots: *zend.Array, format: i64) !*zend.String {
        const opts = native.nbt.options(try parseFormat(format, 2), native.nbt.max_depth);
        const arena = scratch.begin();
        defer scratch.end(arena);
        var writer: Writer = .{ .arena = arena.allocator() };
        const documents = try arena.allocator().alloc(nbt.Document, roots.len());
        var values = roots.fastValueIterator();
        for (documents) |*document| document.* = try writer.root(values.next().?);
        return render(arena.allocator(), documents, opts);
    }
};

fn readInto(data: []const u8, format: i64, start: ?i64, max_depth: ?i64, out: *c.zval) !usize {
    const fmt = try parseFormat(format, 2);
    const from = try parseOffset(data, start, 3);
    const arena = scratch.begin();
    defer scratch.end(arena);
    const parsed = nbt.parsePrefix(arena.allocator(), data[from..], native.nbt.options(fmt, try parseDepth(max_depth, 4))) catch |err| return invalid(err);
    var reader: Reader = .{ .unsigned_int_arrays = fmt != .network };
    try reader.treeRoot(&parsed.document, out);
    return from + parsed.len;
}
