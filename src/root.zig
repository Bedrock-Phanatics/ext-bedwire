const std = @import("std");
const phpz = @import("phpz");
const native = @import("native");

const packet = @import("php/packet.zig");
const protocol_php = @import("php/protocol.zig");

const c = phpz.c;

/// PHP owns signal handling, so the threads the extension starts skip Zig's alternate signal stack.
pub const std_options: std.Options = .{ .signal_stack_size = null };

comptime {
    const extension = @import("extension_info");
    phpz.module(.{
        .name = extension.name,
        .version = extension.version,
        .classes = &.{ ExceptionClass, BackpressureClass, PacketExceptionClass, NbtExceptionClass, ServerClass, ProtocolClass, PacketIdClass, NbtClass },
        .module_startup_fn = startup,
        .request_shutdown_fn = finishRequest,
        .info_fn = info,
    });
}

fn info(m: *phpz.ModuleEntry) void {
    phpz.info.table.start();
    phpz.info.table.header(.{ "bedwire support", "enabled" });
    phpz.info.table.row(.{ "version", m.version });
    phpz.info.table.row(.{ "transport", "NetherNet" });
    phpz.info.table.row(.{ "protocol", std.fmt.comptimePrint("{d} ({s})", .{ native.protocol.protocol_version, native.protocol.minecraft_version }) });
    phpz.info.table.end();
}

/// Interns packet field names and publishes the constants that come from protocol-zig rather than the stub.
fn startup() !void {
    packet.intern();
    const protocol_entry = ProtocolClass.entry.ptr();
    c.zend_declare_class_constant_long(protocol_entry, "VERSION", "VERSION".len, native.protocol.protocol_version);
    c.zend_declare_class_constant_stringl(protocol_entry, "MINECRAFT_VERSION", "MINECRAFT_VERSION".len, native.protocol.minecraft_version.ptr, native.protocol.minecraft_version.len);
    const ids = PacketIdClass.entry.ptr();
    inline for (@typeInfo(packet.Kind).@"enum".field_names) |name| {
        const constant = comptime upper(name);
        c.zend_declare_class_constant_long(ids, constant.ptr, constant.len, native.protocol.registry.packetId(@field(packet.Kind, name)).?);
    }
}

fn finishRequest() !void {
    @import("php/scratch.zig").release();
}

fn upper(comptime name: []const u8) [:0]const u8 {
    comptime {
        @setEvalBranchQuota(100_000);
        var out: [name.len:0]u8 = undefined;
        for (name, 0..) |byte, i| out[i] = std.ascii.toUpper(byte);
        const final = out;
        return &final;
    }
}

pub const ExceptionClass = phpz.Class("Bedwire\\Exception", struct {}, .{ .register = struct {
    fn register(register_fn: anytype) *phpz.ClassEntry {
        return register_fn(.{phpz.globals.class.entry("RuntimeException")});
    }
}.register });

pub const BackpressureClass = phpz.Class("Bedwire\\BackpressureException", struct {}, .{ .register = struct {
    fn register(register_fn: anytype) *phpz.ClassEntry {
        return register_fn(.{ExceptionClass.entry.ptr()});
    }
}.register });

pub const PacketExceptionClass = phpz.Class("Bedwire\\PacketException", struct {}, .{ .register = struct {
    fn register(register_fn: anytype) *phpz.ClassEntry {
        return register_fn(.{ExceptionClass.entry.ptr()});
    }
}.register });

pub const NbtExceptionClass = phpz.Class("Bedwire\\NbtException", struct {}, .{ .register = struct {
    fn register(register_fn: anytype) *phpz.ClassEntry {
        return register_fn(.{ExceptionClass.entry.ptr()});
    }
}.register });

const ServerClass = @import("php/server.zig").Class;
const ProtocolClass = phpz.Class("Bedwire\\Protocol", protocol_php.Protocol, .{});
const PacketIdClass = phpz.Class("Bedwire\\PacketId", struct {}, .{});
const NbtClass = phpz.Class("Bedwire\\Nbt", @import("php/nbt.zig").Nbt, .{});
