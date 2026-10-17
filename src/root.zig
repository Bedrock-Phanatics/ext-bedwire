const std = @import("std");
const phpz = @import("phpz");
const native = @import("native");

const Array = phpz.zend.Array;
const String = phpz.zend.String;
const Zval = phpz.Zval;
const errors = phpz.errors;

// The network thread outlives requests so it cannot use the Zend allocator.
const gpa = std.heap.c_allocator;

comptime {
    const extension = @import("extension_info");
    phpz.module(.{
        .name = extension.name,
        .version = extension.version,
        .classes = &.{ ExceptionClass, BackpressureClass, ServerClass, NbtClass },
        .info_fn = info,
    });
}

fn info(m: *phpz.ModuleEntry) void {
    phpz.info.table.start();
    phpz.info.table.header(.{ "bedwire support", "enabled" });
    phpz.info.table.row(.{ "version", m.version });
    phpz.info.table.row(.{ "protocol", std.fmt.comptimePrint("{d}", .{native.protocol_version}) });
    phpz.info.table.end();
}

const ExceptionClass = phpz.Class("Bedwire\\Exception", struct {}, .{ .register = struct {
    fn register(register_fn: anytype) *phpz.ClassEntry {
        return register_fn(.{phpz.globals.class.entry("RuntimeException")});
    }
}.register });

const BackpressureClass = phpz.Class("Bedwire\\BackpressureException", struct {}, .{ .register = struct {
    fn register(register_fn: anytype) *phpz.ClassEntry {
        return register_fn(.{ExceptionClass.entry.ptr()});
    }
}.register });

fn fail(comptime format: [:0]const u8, args: anytype) errors.Exception {
    return errors.throwExceptionEx(ExceptionClass.entry, 0, format, args);
}

fn backpressure() errors.Exception {
    return errors.throwException(BackpressureClass.entry, "bedwire queue is full", 0);
}

const Server = struct {
    host: ?*native.Host = null,
    owner: std.Thread.Id = 0,

    fn deinit(self: *Server) void {
        if (self.host) |host| host.destroy();
        self.host = null;
    }

    fn get(self: *Server) !*native.Host {
        const host = self.host orelse return errors.throwError(null, "Bedwire\\Server is not initialized", .{});
        if (std.Thread.getCurrentId() != self.owner) return errors.throwError(null, "Bedwire\\Server used from another thread", .{});
        return host;
    }

    fn live(self: *Server) !*native.Host {
        const host = try self.get();
        if (!host.running()) return fail("server is stopped", .{});
        return host;
    }

    pub fn __construct(address: []const u8, port: i64, advertisement: []const u8, options: ?*Array) !Server {
        const port_value = std.math.cast(u16, port) orelse return errors.argumentValueError(2, "must be between 0 and 65535", .{});
        var config: native.Config = .{
            .address = std.Io.net.IpAddress.parse(address, port_value) catch return errors.argumentValueError(1, "must be an IP address", .{}),
            .advertisement = advertisement,
        };
        var prefixes: [native.Config.max_raw_prefixes][]const u8 = undefined;
        if (options) |table| try parseOptions(table, &config, &prefixes);

        const host = native.Host.start(gpa, config) catch |err| return switch (err) {
            error.InvalidConfig => errors.argumentValueError(4, "contains an out-of-range value", .{}),
            else => fail("cannot start server: %s", .{@errorName(err).ptr}),
        };
        return .{ .host = host, .owner = std.Thread.getCurrentId() };
    }

    pub fn stop(self: *Server, timeout_ms: ?i64) !void {
        const host = try self.get();
        const timeout = std.math.cast(u32, timeout_ms orelse 2000) orelse return errors.argumentValueError(1, "must be between 0 and 4294967295", .{});
        host.stop(timeout);
    }

    pub fn isRunning(self: *Server) !bool {
        return (try self.get()).running();
    }

    pub fn getPort(self: *Server) !i64 {
        return (try self.get()).local_address.getPort();
    }

    pub fn poll(self: *Server, max_events: ?i64, timeout_ms: ?i64) !*Array {
        const host = try self.get();
        const max = std.math.cast(u32, max_events orelse 4096) orelse return errors.argumentValueError(1, "must be between 1 and 1048576", .{});
        if (max == 0 or max > 1 << 20) return errors.argumentValueError(1, "must be between 1 and 1048576", .{});
        const timeout = std.math.cast(u32, timeout_ms orelse 0) orelse return errors.argumentValueError(2, "must be between 0 and 4294967295", .{});

        host.waitEvents(timeout);
        const result = Array.init(@as(u32, @min(max, 256)) * 3);
        var count: u32 = 0;
        while (count < max) : (count += 1) {
            const event = host.nextEvent() orelse break;
            appendEvent(result, event);
        }
        host.releaseEvents();
        return result;
    }

    pub fn send(self: *Server, session: i64, packet: []const u8) !bool {
        return (try self.queue(session, &.{packet}, false)) != null;
    }

    pub fn sendBatch(self: *Server, session: i64, packets: *Array) !bool {
        var slices: [native.max_packets_per_batch][]const u8 = undefined;
        return (try self.queue(session, try collect(packets, &slices, 2), false)) != null;
    }

    pub fn sendWithReceipt(self: *Server, session: i64, packets: *Array) !phpz.Mixed(&.{ .int, .bool }) {
        var slices: [native.max_packets_per_batch][]const u8 = undefined;
        const receipt = try self.queue(session, try collect(packets, &slices, 2), true) orelse return .{ .bool = false };
        return .{ .int = @intCast(receipt) };
    }

    pub fn disconnect(self: *Server, session: i64) !bool {
        const host = try self.get();
        return accepted(host.disconnect(@bitCast(session)), 1);
    }

    pub fn enableEncryption(self: *Server, session: i64, handshake: []const u8, key: []const u8) !bool {
        const host = try self.get();
        if (key.len != native.key_len) return errors.argumentValueError(3, "must be exactly 32 bytes", .{});
        return accepted(host.enableEncryption(@bitCast(session), handshake, key[0..native.key_len]), 2);
    }

    pub fn acceptLogin(self: *Server, session: i64, client_key: []const u8) !bool {
        const host = try self.get();
        return accepted(host.acceptLogin(@bitCast(session), client_key), 2);
    }

    pub fn setAdvertisement(self: *Server, advertisement: []const u8) !void {
        const host = try self.live();
        _ = try accepted(host.setAdvertisement(advertisement), 1);
    }

    pub fn blockAddress(self: *Server, address: []const u8, seconds: ?i64) !void {
        const host = try self.live();
        const duration = std.math.cast(u32, seconds orelse 300) orelse return errors.argumentValueError(2, "must be between 0 and 4294967295", .{});
        _ = try accepted(host.blockAddress(try parseAddress(address, 0, 1), duration), 1);
    }

    pub fn unblockAddress(self: *Server, address: []const u8) !void {
        const host = try self.live();
        _ = try accepted(host.unblockAddress(try parseAddress(address, 0, 1)), 1);
    }

    pub fn sendRaw(self: *Server, address: []const u8, port: i64, payload: []const u8) !void {
        const host = try self.live();
        const port_value = std.math.cast(u16, port) orelse return errors.argumentValueError(2, "must be between 0 and 65535", .{});
        _ = try accepted(host.sendRaw(try parseAddress(address, port_value, 1), payload), 3);
    }

    pub fn getStatistics(self: *Server) !*Array {
        const host = try self.get();
        const stats = host.statistics();
        const result = Array.init(native.stat_names.len + 2);
        inline for (native.stat_names) |name| put(result, name, @intCast(@field(stats, name)));
        put(result, "command_queue_bytes", @intCast(host.shared.commands.usedBytes()));
        put(result, "event_queue_bytes", @intCast(host.shared.events.usedBytes()));
        return result;
    }

    fn queue(self: *Server, session: i64, packets: []const []const u8, receipt: bool) !?u64 {
        const host = try self.get();
        return host.send(@bitCast(session), packets, receipt) catch |err| switch (err) {
            error.Closed => null,
            error.Backpressure => backpressure(),
            error.TooLarge => errors.argumentValueError(2, "exceeds the maximum batch size", .{}),
            error.TooManyPackets => errors.argumentValueError(2, "has more than 1024 packets", .{}),
            error.EmptyBatch => errors.argumentValueError(2, "must not be empty", .{}),
        };
    }
};

const ServerClass = phpz.Class("Bedwire\\Server", Server, .{ .init = .default, .deinit = Server.deinit });

const Nbt = struct {
    pub fn __construct() !void {
        return errors.throwError(null, "Bedwire\\Nbt cannot be instantiated", .{});
    }

    pub fn transcode(data: []const u8, from: i64, to: i64, max_depth: ?i64) !*String {
        const source = std.enums.fromInt(native.nbt.Format, from) orelse return errors.argumentValueError(2, "must be a Bedwire\\Nbt format", .{});
        const target = std.enums.fromInt(native.nbt.Format, to) orelse return errors.argumentValueError(3, "must be a Bedwire\\Nbt format", .{});
        const depth = std.math.cast(usize, max_depth orelse 512) orelse return errors.argumentValueError(4, "must be between 1 and 512", .{});
        if (depth == 0 or depth > 512) return errors.argumentValueError(4, "must be between 1 and 512", .{});
        const out = native.nbt.transcode(phpz.heap.php_allocator, data, source, target, .{ .max_depth = depth }) catch |err| {
            return fail("invalid NBT: %s", .{@errorName(err).ptr});
        };
        defer phpz.heap.php_allocator.free(out);
        return String.init(out, false);
    }
};

const NbtClass = phpz.Class("Bedwire\\Nbt", Nbt, .{});

fn accepted(result: native.SendError!void, arg: u32) !bool {
    result catch |err| return switch (err) {
        error.Closed => false,
        error.Backpressure => backpressure(),
        error.TooLarge, error.TooManyPackets, error.EmptyBatch => errors.argumentValueError(arg, "has an invalid length", .{}),
    };
    return true;
}

fn collect(packets: *Array, slices: *[native.max_packets_per_batch][]const u8, arg: u32) ![]const []const u8 {
    var count: usize = 0;
    var values = packets.valueIterator();
    while (values.next()) |raw| {
        var value = raw;
        if (Zval.raw.is(value, .reference)) value = Zval.raw.asUnchecked(value, .reference).val();
        if (!Zval.raw.is(value, .string)) return errors.argumentTypeError(arg, "must contain only strings", .{});
        if (count == slices.len) return errors.argumentValueError(arg, "has more than 1024 packets", .{});
        slices[count] = Zval.raw.asUnchecked(value, .string);
        count += 1;
    }
    return slices[0..count];
}

fn parseAddress(text: []const u8, port: u16, arg: u32) !std.Io.net.IpAddress {
    return std.Io.net.IpAddress.parse(text, port) catch errors.argumentValueError(arg, "must be an IP address", .{});
}

fn parseOptions(table: *Array, config: *native.Config, prefixes: *[native.Config.max_raw_prefixes][]const u8) !void {
    var entries = table.iterator();
    while (entries.next()) |entry| {
        const key = switch (entry.key) {
            .string => |name| name,
            .int => return errors.argumentValueError(4, "must use string keys", .{}),
        };
        var value = entry.value;
        if (Zval.raw.is(value, .reference)) value = Zval.raw.asUnchecked(value, .reference).val();

        if (std.mem.eql(u8, key, "encryption")) {
            if (!Zval.raw.is(value, .bool)) return errors.argumentTypeError(4, "option \"encryption\" must be bool", .{});
            config.encryption = Zval.raw.asUnchecked(value, .bool);
        } else if (std.mem.eql(u8, key, "raw_prefixes")) {
            if (!Zval.raw.is(value, .array)) return errors.argumentTypeError(4, "option \"raw_prefixes\" must be a list of strings", .{});
            const list = Zval.raw.asUnchecked(value, .array);
            var count: usize = 0;
            var items = list.valueIterator();
            while (items.next()) |item| {
                if (!Zval.raw.is(item, .string)) return errors.argumentTypeError(4, "option \"raw_prefixes\" must be a list of strings", .{});
                if (count == prefixes.len) return errors.argumentValueError(4, "option \"raw_prefixes\" has more than 8 entries", .{});
                prefixes[count] = Zval.raw.asUnchecked(item, .string);
                count += 1;
            }
            config.raw_prefixes = prefixes[0..count];
        } else {
            if (!Zval.raw.is(value, .int)) return errors.argumentTypeError(4, "option \"%.*s\" must be int", named(key));
            const number = Zval.raw.asUnchecked(value, .int);
            if (number < 0) return errors.argumentValueError(4, "option \"%.*s\" must not be negative", named(key));
            if (std.mem.eql(u8, key, "guid")) {
                config.guid = @intCast(number);
                continue;
            }
            const small = std.math.cast(u32, number) orelse return errors.argumentValueError(4, "option \"%.*s\" is out of range", named(key));
            inline for (int_options) |name| {
                if (std.mem.eql(u8, key, name)) {
                    @field(config, name) = small;
                    break;
                }
            } else return errors.argumentValueError(4, "has unknown option \"%.*s\"", named(key));
        }
    }
}

const int_options = .{ "max_sessions", "packet_rate", "ping_interval_ms", "max_receipts", "max_blocked", "handshake_rate", "raw_rate", "command_queue_bytes", "event_queue_bytes", "max_batch_bytes" };

fn named(key: []const u8) struct { c_int, [*]const u8 } {
    return .{ @intCast(@min(key.len, 64)), key.ptr };
}

fn put(array: *Array, key: []const u8, value: i64) void {
    var zval = Zval.raw.init(.int, value);
    _ = array.update(key, &zval);
}

fn appendInt(array: *Array, value: i64) void {
    var zval = Zval.raw.init(.int, value);
    _ = array.append(&zval);
}

fn appendString(array: *Array, bytes: []const u8) void {
    var zval = Zval.raw.init(.str, String.init(bytes, false));
    _ = array.append(&zval);
}

fn appendArray(array: *Array, value: *Array) void {
    var zval = Zval.raw.init(.array, value);
    _ = array.append(&zval);
}

fn appendEvent(result: *Array, event: native.Delivered) void {
    appendInt(result, @backingInt(std.meta.activeTag(event)));
    switch (event) {
        .packet => |packet| {
            appendInt(result, @bitCast(packet.session));
            appendString(result, packet.bytes);
        },
        .connect => |connect| {
            appendInt(result, @bitCast(connect.session));
            const details = Array.init(3);
            appendString(details, connect.address);
            appendInt(details, connect.port);
            appendInt(details, @bitCast(connect.guid));
            appendArray(result, details);
        },
        .disconnect => |disconnect| {
            appendInt(result, @bitCast(disconnect.session));
            appendInt(result, @backingInt(disconnect.reason));
        },
        .receipt_ack, .receipt_failed, .ping => |value| {
            appendInt(result, @bitCast(value.session));
            appendInt(result, @intCast(@min(value.value, std.math.maxInt(i64))));
        },
        .raw => |raw| {
            appendInt(result, 0);
            const details = Array.init(3);
            appendString(details, raw.address);
            appendInt(details, raw.port);
            appendString(details, raw.bytes);
            appendArray(result, details);
        },
    }
}
