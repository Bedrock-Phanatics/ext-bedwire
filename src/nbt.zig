const std = @import("std");
const nbt = @import("nbt");

pub const Format = enum(u8) { java, bedrock, network };

pub const Limits = struct {
    max_bytes: usize = 16 * 1024 * 1024,
    max_depth: usize = 512,
};

pub const Error = error{ InvalidFormat, InvalidOptions } || nbt.Error;

/// Validates one root tag and re-encodes it, without building PHP values.
/// Trailing bytes are rejected. The caller owns the result.
pub fn transcode(allocator: std.mem.Allocator, data: []const u8, from: Format, to: Format, limits: Limits) Error![]u8 {
    if (limits.max_depth == 0 or limits.max_depth > 512) return error.InvalidOptions;
    var input = options(from, limits);
    input.reject_trailing_bytes = true;
    var document = try nbt.parse(allocator, data, input);
    defer document.deinit(allocator);
    return nbt.serialize(allocator, document, options(to, limits));
}

fn options(format: Format, limits: Limits) nbt.Options {
    var result: nbt.Options = switch (format) {
        .java => .java,
        .bedrock => .bedrock,
        .network => .bedrock_network,
    };
    result.max_depth = limits.max_depth;
    result.max_input_bytes = limits.max_bytes;
    result.max_decompressed_bytes = limits.max_bytes;
    result.max_output_bytes = limits.max_bytes;
    result.max_total_decoded_bytes = limits.max_bytes * 4;
    result.max_string_bytes = @min(result.max_string_bytes, limits.max_bytes);
    return result;
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
    return nbt.serialize(allocator, document, options(format, .{}));
}

test "transcoding between formats round trips" {
    const disk = try sample(testing.allocator, .bedrock);
    defer testing.allocator.free(disk);
    const network = try sample(testing.allocator, .network);
    defer testing.allocator.free(network);

    const converted = try transcode(testing.allocator, disk, .bedrock, .network, .{});
    defer testing.allocator.free(converted);
    try testing.expectEqualSlices(u8, network, converted);

    const back = try transcode(testing.allocator, converted, .network, .bedrock, .{});
    defer testing.allocator.free(back);
    try testing.expectEqualSlices(u8, disk, back);
}

test "malformed, truncated, trailing and oversized input is refused" {
    const disk = try sample(testing.allocator, .bedrock);
    defer testing.allocator.free(disk);

    for (0..disk.len) |len| {
        try testing.expect(std.meta.isError(transcode(testing.allocator, disk[0..len], .bedrock, .network, .{})));
    }
    var trailing = try testing.allocator.alloc(u8, disk.len + 1);
    defer testing.allocator.free(trailing);
    @memcpy(trailing[0..disk.len], disk);
    trailing[disk.len] = 0;
    try testing.expect(std.meta.isError(transcode(testing.allocator, trailing, .bedrock, .network, .{})));
    try testing.expect(std.meta.isError(transcode(testing.allocator, disk, .bedrock, .network, .{ .max_bytes = disk.len - 1 })));
    try testing.expectError(error.InvalidOptions, transcode(testing.allocator, disk, .bedrock, .network, .{ .max_depth = 0 }));
}

test "deep nesting stops at the depth limit" {
    var data: [4096]u8 = undefined;
    var len: usize = 0;
    // Nested compounds: tag 10, empty name.
    for (0..1000) |_| {
        data[len..][0..3].* = .{ 10, 0, 0 };
        len += 3;
    }
    try testing.expect(std.meta.isError(transcode(testing.allocator, data[0..len], .bedrock, .network, .{ .max_depth = 64 })));
}

test "random bytes never crash the decoder" {
    var prng: std.Random.DefaultPrng = .init(0x5eed);
    const random = prng.random();
    var buffer: [256]u8 = undefined;
    for (0..5000) |_| {
        const len = random.uintLessThan(usize, buffer.len);
        random.bytes(buffer[0..len]);
        if (len != 0) buffer[0] = 10;
        if (transcode(testing.allocator, buffer[0..len], .network, .bedrock, .{ .max_bytes = 4096 })) |out| testing.allocator.free(out) else |_| {}
    }
}
