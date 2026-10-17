const std = @import("std");

const IpAddress = std.Io.net.IpAddress;

pub const Key = [17]u8;
pub const max_text = 45;

pub fn key(address: IpAddress) Key {
    var out: Key = @splat(0);
    switch (unmap(address)) {
        .ip4 => |ip4| {
            out[0] = 4;
            @memcpy(out[1..5], &ip4.bytes);
        },
        .ip6 => |ip6| {
            out[0] = 6;
            @memcpy(out[1..17], &ip6.bytes);
        },
    }
    return out;
}

pub fn unmap(address: IpAddress) IpAddress {
    if (address == .ip6) {
        const bytes = address.ip6.bytes;
        if (std.mem.allEqual(u8, bytes[0..10], 0) and bytes[10] == 0xff and bytes[11] == 0xff) {
            return .{ .ip4 = .{ .bytes = bytes[12..16].*, .port = address.ip6.port } };
        }
    }
    return address;
}

pub fn reachable(local: IpAddress) IpAddress {
    return switch (local) {
        .ip4 => |ip4| if (std.mem.allEqual(u8, &ip4.bytes, 0)) .{ .ip4 = .loopback(ip4.port) } else local,
        .ip6 => |ip6| if (std.mem.allEqual(u8, &ip6.bytes, 0)) .{ .ip6 = .loopback(ip6.port) } else local,
    };
}

pub fn format(address: IpAddress, buffer: *[max_text]u8) []const u8 {
    switch (unmap(address)) {
        .ip4 => |ip4| return std.fmt.bufPrint(buffer, "{d}.{d}.{d}.{d}", .{ ip4.bytes[0], ip4.bytes[1], ip4.bytes[2], ip4.bytes[3] }) catch unreachable,
        .ip6 => |ip6| {
            var groups: [8]u16 = undefined;
            for (&groups, 0..) |*group, i| group.* = std.mem.readInt(u16, ip6.bytes[i * 2 ..][0..2], .big);

            var best_start: usize = 8;
            var best_len: usize = 0;
            var i: usize = 0;
            while (i < 8) {
                if (groups[i] != 0) {
                    i += 1;
                    continue;
                }
                const start = i;
                while (i < 8 and groups[i] == 0) i += 1;
                if (i - start > best_len and i - start > 1) {
                    best_start = start;
                    best_len = i - start;
                }
            }

            var writer: std.Io.Writer = .fixed(buffer);
            i = 0;
            while (i < 8) {
                if (i == best_start) {
                    writer.writeAll(if (i == 0) "::" else ":") catch unreachable;
                    i += best_len;
                    continue;
                }
                writer.print("{x}", .{groups[i]}) catch unreachable;
                if (i != 7) writer.writeByte(':') catch unreachable;
                i += 1;
            }
            return writer.buffered();
        },
    }
}

const testing = std.testing;

fn formatted(text: []const u8) ![]const u8 {
    const S = struct {
        var buffer: [max_text]u8 = undefined;
    };
    return format(try IpAddress.parse(text, 1), &S.buffer);
}

test "addresses format without their port" {
    try testing.expectEqualStrings("127.0.0.1", try formatted("127.0.0.1"));
    try testing.expectEqualStrings("::1", try formatted("::1"));
    try testing.expectEqualStrings("::", try formatted("::"));
    try testing.expectEqualStrings("2001:db8::1", try formatted("2001:db8:0:0:0:0:0:1"));
    try testing.expectEqualStrings("2001:db8:0:1:1:1:1:1", try formatted("2001:db8:0:1:1:1:1:1"));
    try testing.expectEqualStrings("fe80::", try formatted("fe80::"));
    try testing.expectEqualStrings("10.0.0.7", try formatted("::ffff:10.0.0.7"));
    try testing.expectEqualStrings("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff", try formatted("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"));
}

test "keys ignore ports and IPv4 mapping" {
    const a = try IpAddress.parse("10.0.0.7", 1);
    const b = try IpAddress.parse("::ffff:10.0.0.7", 2);
    const c = try IpAddress.parse("10.0.0.8", 1);
    try testing.expectEqual(key(a), key(b));
    try testing.expect(!std.mem.eql(u8, &key(a), &key(c)));
}

test "unspecified listeners are reached through loopback" {
    const reached = reachable(try IpAddress.parse("0.0.0.0", 19132));
    try testing.expectEqual(@as(u16, 19132), reached.getPort());
    try testing.expectEqualSlices(u8, &.{ 127, 0, 0, 1 }, &reached.ip4.bytes);
    const six = reachable(try IpAddress.parse("::", 5));
    try testing.expectEqual(@as(u8, 1), six.ip6.bytes[15]);
}
