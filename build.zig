const std = @import("std");

const Phpz = @import("phpz").Phpz;

const package = @import("build.zig.zon");
const extension_name = "bedwire";

pub fn build(b: *std.Build) void {
    const version = @import("builtin").zig_version;
    if (comptime version.major != 0 or version.minor != 17) {
        @compileError("ext-bedwire requires Zig 0.17");
    }

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const php_include_dir = b.option([]const u8, "php-include-dir", "PHP include directory (main/, Zend/, TSRM/, ext/)") orelse "/usr/include/php";
    const php_lib_dir = b.option([]const u8, "php-lib-dir", "Windows only: PHP SDK library directory containing php8*.lib");
    const windows_zts = b.option(bool, "windows-zts", "Windows only: link against the thread-safe PHP library") orelse false;
    const windows_debug = b.option(bool, "windows-debug", "Windows only: build against a debug PHP SDK") orelse false;
    const libc_file = b.option([]const u8, "libc-file", "Libc paths file for C translation and extension compilation");
    const php = b.option([]const u8, "php", "PHP binary used for PHPT tests and benchmarks") orelse "php";
    const stress_rounds = b.option(usize, "stress-rounds", "Rounds for the start/stop and churn stress tests") orelse 3;
    const native_prefix = b.option([]const u8, "native-prefix", "Install prefix of nethernet-zig's patched libdatachannel") orelse
        b.graph.environ_map.get("NETHERNET_NATIVE_PREFIX") orelse ".deps/native";

    const libdeflate = b.option(bool, "libdeflate", "Compress session batches with libdeflate rather than std's deflate") orelse true;
    const imports = nativeImports(b, target, optimize, native_prefix, libdeflate, libc_file);
    const native = b.createModule(.{
        .root_source_file = b.path("src/native.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &imports,
    });

    const phpz_dep = b.dependency("phpz", .{});
    const phpz = Phpz.init(phpz_dep, .{
        .translator = .{
            .c_source_file = b.path("bedwire.h"),
            .target = target,
            .optimize = optimize,
        },
        .libc_file = if (libc_file) |file| .{ .cwd_relative = file } else null,
        .php_include_dir = .{ .cwd_relative = php_include_dir },
        .php_lib_dir = if (php_lib_dir) |dir| .{ .cwd_relative = dir } else null,
        .windows_zts = windows_zts,
        .windows_debug = windows_debug,
    });

    const extension = phpz.addExtension(b, .{
        .name = extension_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "native", .module = native },
                imports[2],
            },
        }),
    });
    const extension_info = b.addOptions();
    extension_info.addOption([:0]const u8, "name", extension_name);
    extension_info.addOption([:0]const u8, "version", package.version);
    extension.root_module.addOptions("extension_info", extension_info);

    const filename = if (target.result.os.tag == .windows) "php_" ++ extension_name ++ ".dll" else extension_name ++ ".so";
    const install = b.addInstallFileWithDir(extension.getEmittedBin(), .{ .custom = "modules" }, filename);
    b.getInstallStep().dependOn(&install.step);
    const binary = extension.getEmittedBin();
    const library_path = b.pathJoin(&.{ native_prefix, if (target.result.os.tag == .windows) "bin" else "lib" });

    const options = b.addOptions();
    options.addOption(usize, "stress_rounds", stress_rounds);
    const suite = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tests/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &(imports ++ [_]std.Build.Module.Import{
            .{ .name = "native", .module = native },
            .{ .name = "build_options", .module = options.createModule() },
        }),
    }) });
    const test_step = b.step("test", "Run Zig unit and integration tests");
    for ([_]*std.Build.Step.Compile{ b.addTest(.{ .root_module = native }), suite }) |artifact| {
        const run = b.addRunArtifact(artifact);
        addLibraryPath(b, run, target, library_path);
        test_step.dependOn(&run.step);
    }

    const phpt = b.addSystemCommand(&.{php});
    phpt.addFileArg(phpz_dep.path("tools/php/run-tests.php"));
    phpt.addArgs(&.{ "-q", "--show-diff", "-p", php, "-d" });
    phpt.addPrefixedFileArg("extension=", binary);
    phpt.addArg("tests/phpt");
    phpt.setCwd(b.path("."));
    phpt.has_side_effects = true;
    addLibraryPath(b, phpt, target, library_path);
    b.step("phpt", "Run PHPT tests against the built extension").dependOn(&phpt.step);

    const bench_imports = nativeImports(b, target, .ReleaseFast, native_prefix, libdeflate, libc_file);
    const bench_native = b.createModule(.{
        .root_source_file = b.path("src/native.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &bench_imports,
    });
    const bench_all = bench_imports ++ [_]std.Build.Module.Import{.{ .name = "native", .module = bench_native }};
    const bench = b.addExecutable(.{ .name = "bedwire-bench", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/bench/main.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &bench_all,
    }) });
    const run_bench = b.addRunArtifact(bench);
    addLibraryPath(b, run_bench, target, library_path);
    run_bench.addPassthruArgs();
    b.step("bench", "Run native protocol, session, NBT and transport benchmarks").dependOn(&run_bench.step);

    const client = b.addExecutable(.{ .name = "bedwire-bench-client", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/bench/client.zig"),
        .target = target,
        .optimize = .ReleaseFast,
        .imports = &bench_all,
    }) });
    const install_client = b.addInstallArtifact(client, .{});
    b.step("bench-client", "Install the out-of-process NetherNet load client").dependOn(&install_client.step);

    const join = b.addExecutable(.{ .name = "bedwire-join", .root_module = b.createModule(.{
        .root_source_file = b.path("tests/bench/join.zig"),
        .target = target,
        .optimize = .ReleaseSafe,
        .imports = &bench_all,
    }) });
    b.step("join", "Install a client that joins a server as an offline player").dependOn(&b.addInstallArtifact(join, .{}).step);
    phpt.step.dependOn(&install_client.step);

    const php_bench = b.addSystemCommand(&.{ php, "-n", "-d" });
    php_bench.addPrefixedFileArg("extension=", binary);
    php_bench.addArg("tests/bench/boundary.php");
    php_bench.addArtifactArg(client);
    php_bench.setCwd(b.path("."));
    php_bench.has_side_effects = true;
    addLibraryPath(b, php_bench, target, library_path);
    b.step("bench-php", "Run PHP boundary and end-to-end benchmarks").dependOn(&php_bench.step);

    const docs = b.addExecutable(.{ .name = "bedwire-docs", .root_module = b.createModule(.{
        .root_source_file = b.path("tools/docs.zig"),
        .target = b.graph.host,
        .imports = &.{.{ .name = "bedwire", .module = b.dependency("bedwire", .{ .target = b.graph.host }).module("bedwire") }},
    }) });
    const run_docs = b.addRunArtifact(docs);
    run_docs.addArgs(&.{ "docs/packets.md", "stubs/bedwire_generated.php" });
    run_docs.setCwd(b.path("."));
    b.step("docs", "Regenerate the packet reference and IDE stubs from protocol-zig").dependOn(&run_docs.step);
}

fn nativeImports(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, native_prefix: []const u8, libdeflate: bool, libc_file: ?[]const u8) [3]std.Build.Module.Import {
    const args = .{ .target = target, .optimize = optimize };
    return .{
        .{ .name = "bedwire", .module = b.dependency("bedwire", .{ .target = target, .optimize = optimize, .libdeflate = libdeflate, .@"libc-file" = libc_file }).module("bedwire") },
        .{ .name = "nethernet", .module = b.dependency("nethernet", .{ .target = target, .optimize = optimize, .@"native-prefix" = native_prefix }).module("nethernet") },
        .{ .name = "nbt", .module = b.dependency("nbt", args).module("nbt") },
    };
}

/// libdatachannel is a shared library, so anything that loads the extension needs it on the search path.
fn addLibraryPath(b: *std.Build, run: *std.Build.Step.Run, target: std.Build.ResolvedTarget, path: []const u8) void {
    const name = if (target.result.os.tag == .windows) "PATH" else "LD_LIBRARY_PATH";
    const separator = if (target.result.os.tag == .windows) ";" else ":";
    const current = b.graph.environ_map.get(name);
    run.setEnvironmentVariable(name, if (current) |value| b.fmt("{s}{s}{s}", .{ path, separator, value }) else path);
}
