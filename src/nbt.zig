const std = @import("std");
const nbt = @import("nbt");

pub const Format = enum(u8) { java, bedrock, network };

pub const max_depth = nbt.Options.max_supported_depth;

/// PocketMine's maxDepth counts compounds and lists from the root and treats 0 as unlimited,
/// while nbt-zig counts every level.
pub fn depthFromPocketMine(depth: u32) usize {
    if (depth == 0 or depth >= max_depth) return max_depth;
    return depth + 1;
}

/// Matches PocketMine: strings are opaque bytes up to 32767, and the first of duplicate names wins.
pub fn options(format: Format, depth: usize) nbt.Options {
    var result: nbt.Options = switch (format) {
        .java => .java,
        .bedrock => .bedrock,
        .network => .bedrock_network,
    };
    result.raw_strings = true;
    result.duplicate_names = .keep_first;
    result.max_string_bytes = std.math.maxInt(i16);
    result.max_depth = depth;
    result.max_input_bytes = max_document_bytes;
    result.max_output_bytes = max_document_bytes;
    result.max_total_decoded_bytes = max_document_bytes * 4;
    return result;
}

pub const max_document_bytes = 64 * 1024 * 1024;

/// Converts one root tag between encodings, rejecting trailing bytes.
pub fn transcode(allocator: std.mem.Allocator, data: []const u8, from: Format, to: Format, depth: usize) nbt.Error![]u8 {
    var input = options(from, depth);
    input.reject_trailing_bytes = true;
    var document = try nbt.parse(allocator, data, input);
    defer document.deinit(allocator);
    return nbt.serialize(allocator, document, options(to, depth));
}

const testing = std.testing;

fn sample(allocator: std.mem.Allocator, format: Format) ![]u8 {
    var compound = nbt.builder.Compound.init(allocator);
    defer compound.deinit();
    {
        var text = try nbt.builder.string(allocator, "minecraft:stone");
        errdefer text.deinit(allocator);
        try compound.add("name", text);
    }
    try compound.add("count", .{ .int = -42 });
    try compound.add("damage", .{ .short = 7 });
    var root = try compound.finish();
    errdefer root.deinit(allocator);
    var document = try nbt.Document.init(allocator, "", root);
    defer document.deinit(allocator);
    return nbt.serialize(allocator, document, options(format, max_depth));
}

test "transcoding between formats round trips" {
    const disk = try sample(testing.allocator, .bedrock);
    defer testing.allocator.free(disk);
    const network = try sample(testing.allocator, .network);
    defer testing.allocator.free(network);

    const converted = try transcode(testing.allocator, disk, .bedrock, .network, max_depth);
    defer testing.allocator.free(converted);
    try testing.expectEqualSlices(u8, network, converted);

    const back = try transcode(testing.allocator, converted, .network, .bedrock, max_depth);
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, disk, back);
}

test "malformed, truncated and trailing input is refused" {
    const disk = try sample(testing.allocator, .bedrock);
    defer testing.allocator.free(disk);

    for (0..disk.len) |len| {
        try testing.expect(std.meta.isError(transcode(testing.allocator, disk[0..len], .bedrock, .network, max_depth)));
    }
    var trailing = try testing.allocator.alloc(u8, disk.len + 1);
    defer testing.allocator.free(trailing);
    @memcpy(trailing[0..disk.len], disk);
    trailing[disk.len] = 0;
    try testing.expect(std.meta.isError(transcode(testing.allocator, trailing, .bedrock, .network, max_depth)));
}

test "depth limits follow PocketMine" {
    try testing.expectEqual(@as(usize, max_depth), depthFromPocketMine(0));
    try testing.expectEqual(@as(usize, 2), depthFromPocketMine(1));
    try testing.expectEqual(@as(usize, max_depth), depthFromPocketMine(100_000));

    var data: [4096]u8 = undefined;
    var len: usize = 0;
    for (0..1000) |_| {
        data[len..][0..3].* = .{ 10, 0, 0 };
        len += 3;
    }
    try testing.expect(std.meta.isError(transcode(testing.allocator, data[0..len], .bedrock, .network, 64)));
}

test "random bytes never crash the decoder" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var buffer: [256]u8 = undefined;
    for (0..5000) |_| {
        const len = random.uintLessThan(usize, buffer.len);
        random.bytes(buffer[0..len]);
        if (len != 0) buffer[0] = 10;
        if (transcode(testing.allocator, buffer[0..len], .network, .bedrock, max_depth)) |out| testing.allocator.free(out) else |_| {}
        _ = nbt.scanDocument(buffer[0..len], options(.network, max_depth)) catch {};
    }
}
