const std = @import("std");
const phpz = @import("phpz");
const native = @import("native");
const protocol_php = @import("protocol.zig");
const scratch = @import("scratch.zig");
const root = @import("../root.zig");

const c = phpz.c;
const zend = phpz.zend;
const Zval = phpz.Zval;
const exception = phpz.exception;
const Array = zend.Array;

// The network thread outlives requests so it cannot use the Zend allocator.
const gpa = std.heap.c_allocator;

fn fail(comptime format: [:0]const u8, args: anytype) exception.Error {
    return exception.throwExceptionEx(root.ExceptionClass.entry, 0, format, args);
}

fn backpressure() exception.Error {
    return exception.throwException(root.BackpressureClass.entry, "bedwire queue is full", 0);
}

pub const Class = phpz.Class("Bedwire\\Server", Server, .{ .init = .default, .deinit = Server.deinit });

const Server = struct {
    host: ?*native.Host = null,
    owner: std.Thread.Id = 0,

    fn deinit(self: *Server) void {
        if (self.host) |host| host.destroy();
        self.host = null;
    }

    fn get(self: *Server) !*native.Host {
        const host = self.host orelse return exception.throwError(null, "Bedwire\\Server is not initialized", .{});
        if (std.Thread.getCurrentId() != self.owner) return exception.throwError(null, "Bedwire\\Server used from another thread", .{});
        return host;
    }

    pub fn __construct(address: []const u8, port: i64, options: ?*Array) !Server {
        const port_value = std.math.cast(u16, port) orelse return exception.argumentValueError(2, "must be between 0 and 65535", .{});
        var config: native.Config = .{
            .address = std.Io.net.IpAddress.parse(address, port_value) catch return exception.argumentValueError(1, "must be an IP address", .{}),
        };
        var path: [4096:0]u8 = undefined;
        var lists: Lists = .{};
        if (options) |table| try parseOptions(table, &config, &path, &lists);

        const host = native.Host.start(gpa, config) catch |err| return switch (err) {
            error.InvalidConfig => exception.argumentValueError(3, "contains an out-of-range value", .{}),
            else => fail("cannot start server: %s", .{@errorName(err).ptr}),
        };
        return .{ .host = host, .owner = std.Thread.getCurrentId() };
    }

    pub fn stop(self: *Server, timeout_ms: ?i64) !void {
        const host = try self.get();
        const timeout = std.math.cast(u32, timeout_ms orelse 2000) orelse return exception.argumentValueError(1, "must be between 0 and 4294967295", .{});
        host.stop(timeout);
    }

    pub fn isRunning(self: *Server) !bool {
        return (try self.get()).running();
    }

    pub fn getPort(self: *Server) !i64 {
        return (try self.get()).local_address.getPort();
    }

    pub fn setStatus(self: *Server, name: []const u8, level: []const u8, max_players: i64, game_type: ?i64) !void {
        const host = try self.get();
        if (name.len > native.max_status_text or !std.unicode.utf8ValidateSlice(name)) return exception.argumentValueError(1, "must be valid UTF-8 of at most 256 bytes", .{});
        if (level.len > native.max_status_text or !std.unicode.utf8ValidateSlice(level)) return exception.argumentValueError(2, "must be valid UTF-8 of at most 256 bytes", .{});
        const max = std.math.cast(u32, max_players) orelse return exception.argumentValueError(3, "must not be negative", .{});
        const mode = std.math.cast(i32, game_type orelse 0) orelse return exception.argumentValueError(4, "must be between 0 and 2", .{});
        if (mode < 0 or mode > 2) return exception.argumentValueError(4, "must be between 0 and 2", .{});
        host.setStatus(name, level, max, mode);
    }

    /// Returns a flat `[kind, session, data, ...]` list, which builds one packed array per poll.
    pub fn poll(self: *Server, max_events: ?i64, timeout_ms: ?i64) !*Array {
        const host = try self.get();
        const max = std.math.cast(u32, max_events orelse 4096) orelse return exception.argumentValueError(1, "must be between 1 and 1048576", .{});
        if (max == 0 or max > 1 << 20) return exception.argumentValueError(1, "must be between 1 and 1048576", .{});
        const timeout = std.math.cast(u32, timeout_ms orelse 0) orelse return exception.argumentValueError(2, "must be between 0 and 4294967295", .{});

        host.waitEvents(timeout);
        var list = Array.ListBuilder.init(@as(u32, @min(max, 256)) * 3);
        var count: u32 = 0;
        while (count < max) : (count += 1) {
            const event = host.nextEvent() orelse break;
            appendEvent(&list, event);
        }
        host.releaseEvents();
        return list.finish();
    }

    pub fn send(self: *Server, session: i64, packet: []const u8) !bool {
        return queued((try self.get()).send(@bitCast(session), &.{packet}));
    }

    pub fn sendBatch(self: *Server, session: i64, packets: *Array) !bool {
        var slices: [native.max_packets_per_batch][]const u8 = undefined;
        return queued((try self.get()).send(@bitCast(session), try collect(packets, &slices, 2)));
    }

    /// Encodes packet objects and `[packet, fields]` pairs straight into the send queue next to already encoded
    /// packets, skipping intermediate PHP strings.
    pub fn sendPackets(self: *Server, session: i64, packets: *Array) !bool {
        const host = try self.get();
        if (packets.len() > native.max_packets_per_batch) return exception.argumentValueError(2, "has more than 1024 packets", .{});
        const arena = scratch.begin();
        defer scratch.end(arena);
        const allocator = arena.allocator();
        const items = try allocator.alloc(protocol_php.BatchItem, packets.len());
        var typed: std.ArrayList(u8) = .empty;
        var total: usize = 0;
        var values = packets.fastValueIterator();
        for (items) |*item| {
            const value = deref(values.next().?);
            if (Zval.raw.is(value, .string)) {
                const encoded = Zval.raw.asUnchecked(value, .string);
                if (encoded.len == 0) return exception.argumentValueError(2, "must not contain empty packets", .{});
                item.* = .{ .encoded = encoded };
            } else {
                const entry = try protocol_php.itemOf(value, 2);
                const start = typed.items.len;
                try protocol_php.append(allocator, &typed, entry.kind, entry.fields, entry.sender, entry.target, 2);
                item.* = .{ .typed = .{ .start = start, .end = typed.items.len } };
            }
            total += item.bytes(typed.items).len;
        }
        var batch = host.beginSend(@bitCast(session), items.len, total) catch |err| return queued(err);
        for (items) |item| {
            const bytes = item.bytes(typed.items);
            @memcpy(batch.packet(bytes.len), bytes);
        }
        host.commitSend(batch);
        return true;
    }

    /// Sends a batch body as Bedrock frames it, each packet behind its varint length, compressing it on the network thread.
    pub fn sendRawBatch(self: *Server, session: i64, batch: []const u8, offset: ?i64) !bool {
        const start = std.math.cast(usize, offset orelse 0) orelse return exception.argumentValueError(3, "must not be negative", .{});
        if (start > batch.len) return exception.argumentValueError(3, "is past the end of the batch", .{});
        (try self.get()).sendRawBatch(@bitCast(session), batch[start..]) catch |err| return switch (err) {
            error.MalformedBatch => exception.argumentValueError(2, "is not a batch of varint length-prefixed packets", .{}),
            else => |send_error| queued(send_error),
        };
        return true;
    }

    /// Sends one message on the unreliable channel as it is, without batching, compression or ordering.
    pub fn sendUnreliable(self: *Server, session: i64, payload: []const u8) !bool {
        return queued((try self.get()).sendUnreliable(@bitCast(session), payload));
    }

    /// A handle another thread can pass to waitForEvents, to wake an event loop as soon as events arrive.
    pub fn eventSignal(self: *Server) !i64 {
        return @bitCast((try self.get()).shared.signal_handle);
    }

    /// Blocks the calling thread, which needs no Server of its own, until events are published after the
    /// sequence `seen` or the timeout passes. Returns the new sequence, or null once the server is gone.
    pub fn waitForEvents(handle: i64, seen: i64, timeout_ms: ?i64) !?i64 {
        const timeout = std.math.cast(u32, timeout_ms orelse 1000) orelse return exception.argumentValueError(3, "must be between 0 and 4294967295", .{});
        const sequence = native.signal.wait(@bitCast(handle), @truncate(@as(u64, @bitCast(seen))), timeout) orelse return null;
        return sequence;
    }

    pub fn disconnect(self: *Server, session: i64) !bool {
        return queued((try self.get()).disconnect(@bitCast(session)));
    }

    pub fn acceptLogin(self: *Server, session: i64, client_key: []const u8) !bool {
        return queued((try self.get()).acceptLogin(@bitCast(session), client_key));
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
};

fn queued(result: native.SendError!void) !bool {
    result catch |err| return switch (err) {
        error.Closed => false,
        error.Backpressure => backpressure(),
        error.TooLarge => exception.argumentValueError(2, "exceeds the maximum batch size", .{}),
        error.TooManyPackets => exception.argumentValueError(2, "has more than 1024 packets", .{}),
        error.EmptyBatch => exception.argumentValueError(2, "must not be empty", .{}),
    };
    return true;
}

fn collect(packets: *Array, slices: *[native.max_packets_per_batch][]const u8, arg: u32) ![]const []const u8 {
    var count: usize = 0;
    var values = packets.fastValueIterator();
    while (values.next()) |raw| {
        const value = deref(raw);
        if (!Zval.raw.is(value, .string)) return exception.argumentTypeError(arg, "must contain only strings", .{});
        if (count == slices.len) return exception.argumentValueError(arg, "has more than 1024 packets", .{});
        slices[count] = Zval.raw.asUnchecked(value, .string);
        count += 1;
    }
    return slices[0..count];
}

fn deref(zv: *c.zval) *c.zval {
    return if (Zval.raw.is(zv, .reference)) Zval.raw.asUnchecked(zv, .reference).val() else zv;
}

const int_options = .{ "max_sessions", "packet_rate", "login_timeout_ms", "stats_interval_ms", "max_negotiations", "http_workers", "command_queue_bytes", "event_queue_bytes", "max_batch_bytes", "receive_queue_bytes", "send_buffer_bytes" };
const port_options = .{ "port_range_begin", "port_range_end", "lan_port" };
const bool_options = .{ "authentication", "udp_mux", "unreliable_events" };

/// Option lists borrow PHP's strings, which outlive the constructor call that copies them.
const Lists = struct {
    ice_servers: [native.max_ice_servers][:0]const u8 = undefined,
    trusted_identity_keys: [native.max_trusted_keys][]const u8 = undefined,
};

fn stringList(value: *c.zval, comptime name: []const u8, out: anytype) ![]@TypeOf(out[0]) {
    if (!Zval.raw.is(value, .array)) return exception.argumentTypeError(3, "option \"" ++ name ++ "\" must be a list of strings", .{});
    var count: usize = 0;
    var items = Zval.raw.asUnchecked(value, .array).fastValueIterator();
    while (items.next()) |raw| {
        const item = deref(raw);
        if (!Zval.raw.is(item, .string)) return exception.argumentTypeError(3, "option \"" ++ name ++ "\" must be a list of strings", .{});
        if (count == out.len) return exception.argumentValueError(3, "option \"" ++ name ++ "\" has too many entries", .{});
        const text = Zval.raw.asUnchecked(item, .string);
        if (text.len == 0 or std.mem.indexOfScalar(u8, text, 0) != null) return exception.argumentValueError(3, "option \"" ++ name ++ "\" has an empty or invalid entry", .{});
        // Zend strings are NUL-terminated, so the bytes can be borrowed as C strings.
        out[count] = if (@TypeOf(out[0]) == [:0]const u8) text.ptr[0..text.len :0] else text;
        count += 1;
    }
    return out[0..count];
}

fn parseOptions(table: *Array, config: *native.Config, path: *[4096:0]u8, lists: *Lists) !void {
    var entries = table.iterator();
    while (entries.next()) |entry| {
        const key = switch (entry.key) {
            .string => |name| name,
            .int => return exception.argumentValueError(3, "must use string keys", .{}),
        };
        const value = deref(entry.value);

        if (std.mem.eql(u8, key, "identity_file")) {
            if (!Zval.raw.is(value, .string)) return exception.argumentTypeError(3, "option \"identity_file\" must be string", .{});
            const text = Zval.raw.asUnchecked(value, .string);
            if (text.len == 0 or text.len >= path.len or std.mem.indexOfScalar(u8, text, 0) != null) return exception.argumentValueError(3, "option \"identity_file\" must be a path", .{});
            @memcpy(path[0..text.len], text);
            path[text.len] = 0;
            config.identity_file = path[0..text.len];
            continue;
        }
        if (std.mem.eql(u8, key, "bind_address")) {
            if (!Zval.raw.is(value, .string)) return exception.argumentTypeError(3, "option \"bind_address\" must be string", .{});
            const text = Zval.raw.asUnchecked(value, .string);
            _ = std.Io.net.IpAddress.parse(text, 0) catch return exception.argumentValueError(3, "option \"bind_address\" must be an IP address", .{});
            config.bind_address = text.ptr[0..text.len :0];
            continue;
        }
        if (std.mem.eql(u8, key, "ice_servers")) {
            config.ice_servers = try stringList(value, "ice_servers", &lists.ice_servers);
            continue;
        }
        if (std.mem.eql(u8, key, "trusted_identity_keys")) {
            config.trusted_identity_keys = try stringList(value, "trusted_identity_keys", &lists.trusted_identity_keys);
            continue;
        }
        inline for (bool_options) |name| {
            if (std.mem.eql(u8, key, name)) {
                if (!Zval.raw.is(value, .bool)) return exception.argumentTypeError(3, "option \"" ++ name ++ "\" must be bool", .{});
                @field(config, name) = Zval.raw.asUnchecked(value, .bool);
                break;
            }
        } else {
            if (!Zval.raw.is(value, .int)) return exception.argumentTypeError(3, "option \"%.*s\" must be int", named(key));
            const number = Zval.raw.asUnchecked(value, .int);
            if (number < 0) return exception.argumentValueError(3, "option \"%.*s\" must not be negative", named(key));
            inline for (int_options ++ port_options) |name| {
                if (std.mem.eql(u8, key, name)) {
                    @field(config, name) = std.math.cast(@FieldType(native.Config, name), number) orelse
                        return exception.argumentValueError(3, "option \"%.*s\" is out of range", named(key));
                    break;
                }
            } else return exception.argumentValueError(3, "has unknown option \"%.*s\"", named(key));
        }
    }
}

fn named(key: []const u8) struct { c_int, [*]const u8 } {
    return .{ @intCast(@min(key.len, 64)), key.ptr };
}

fn put(array: *Array, key: []const u8, value: i64) void {
    var zval = Zval.raw.init(.int, value);
    _ = array.update(key, &zval);
}

fn appendEvent(list: *Array.ListBuilder, event: native.Delivered) void {
    list.append(.int, @backingInt(std.meta.activeTag(event)));
    switch (event) {
        .packet => |packet| {
            list.append(.int, @bitCast(packet.session));
            list.append(.string, packet.bytes);
        },
        .connect => |connect| {
            list.append(.int, @bitCast(connect.session));
            var details = Array.ListBuilder.init(4);
            details.appendAssumeCapacity(.string, connect.address);
            details.appendAssumeCapacity(.string, connect.network_id);
            if (connect.identity) |identity| details.appendAssumeCapacity(.string, identity) else details.appendValue(&Zval.raw.nil);
            details.appendAssumeCapacity(.bool, connect.issuer_verified);
            list.append(.array, details.finish());
        },
        .unreliable => |unreliable| {
            list.append(.int, @bitCast(unreliable.session));
            list.append(.string, unreliable.bytes);
        },
        .disconnect => |disconnect| {
            list.append(.int, @bitCast(disconnect.session));
            list.append(.int, @backingInt(disconnect.reason));
        },
        .login => |login| {
            list.append(.int, @bitCast(login.session));
            var details = Array.ListBuilder.init(3);
            details.appendAssumeCapacity(.string, login.name);
            details.appendAssumeCapacity(.string, login.uuid);
            details.appendAssumeCapacity(.string, login.xuid);
            list.append(.array, details.finish());
        },
    }
}
