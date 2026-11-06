const std = @import("std");
const phpz = @import("phpz");

/// PHP owns signal handling, so the threads the extension starts skip Zig's alternate signal stack.
pub const std_options: std.Options = .{ .signal_stack_size = null };

comptime {
    const extension = @import("extension_info");
    phpz.module(.{
        .name = extension.name,
        .version = extension.version,
        .classes = &.{ ExceptionClass, BackpressureClass, NbtExceptionClass, ServerClass, NbtClass },
        .request_shutdown_fn = finishRequest,
        .info_fn = info,
    });
}

fn info(m: *phpz.ModuleEntry) void {
    phpz.info.table.start();
    phpz.info.table.header(.{ "bedwire support", "enabled" });
    phpz.info.table.row(.{ "version", m.version });
    phpz.info.table.row(.{ "transport", "NetherNet" });
    phpz.info.table.end();
}

fn finishRequest() !void {
    @import("php/scratch.zig").release();
}

pub const ExceptionClass = phpz.Class("Bedwire\\Exception", struct {}, .{ .register = struct {
    fn register(register_fn: anytype) *phpz.ClassEntry {
        return register_fn(.{phpz.ClassEntry.builtin("RuntimeException")});
    }
}.register });

pub const BackpressureClass = phpz.Class("Bedwire\\BackpressureException", struct {}, .{ .register = struct {
    fn register(register_fn: anytype) *phpz.ClassEntry {
        return register_fn(.{ExceptionClass.entry});
    }
}.register });

pub const NbtExceptionClass = phpz.Class("Bedwire\\NbtException", struct {}, .{ .register = struct {
    fn register(register_fn: anytype) *phpz.ClassEntry {
        return register_fn(.{ExceptionClass.entry});
    }
}.register });

const ServerClass = @import("php/server.zig").Class;
const NbtClass = phpz.Class("Bedwire\\Nbt", @import("php/nbt.zig").Nbt, .{});
