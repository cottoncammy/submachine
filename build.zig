const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;

comptime {
    const zig_version = builtin.zig_version;
    const required_zig_version: std.SemanticVersion = .{
        .major = 0,
        .minor = 15,
        .patch = 2,
        .pre = null,
    };

    if (zig_version.order(required_zig_version) == .lt) {
        @compileError(std.fmt.comptimePrint(
            "Unsupported Zig version: {f}",
            .{zig_version},
        ));
    }
}

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "use_llvm",
        \\Whether to build with the LLVM backend
    ) orelse true;

    const gpa = b.allocator;

    const root = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "submachine",
        .root_module = root,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    exe.linkLibC();

    var asset_paths: std.ArrayList(std.Build.LazyPath) = .empty;
    defer asset_paths.deinit(gpa);

    if (b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe.linkLibrary(dep.artifact("SDL3"));
    }

    if (b.lazyDependency("sdl_shadercross", .{
        .target = target,
        .optimize = optimize,
        .use_llvm = use_llvm,
    })) |dep| {
        exe.linkLibrary(dep.artifact("sdl-shadercross"));

        const formats = &[_][]const u8{ ".spv", ".json" };

        for (try getShaderFiles(gpa)) |shader| {
            defer gpa.free(shader);
            const in_path = try std.fs.path.join(gpa, &.{ "assets/shaders", shader });
            defer gpa.free(in_path);

            for (formats) |format| {
                const run_shadercross =
                    b.addRunArtifact(dep.artifact("sdl-shadercross-cli"));

                run_shadercross.addFileArg(b.path(in_path));
                run_shadercross.addArg("--output");

                const stem = std.fs.path.stem(shader);
                const out_path = b.fmt("assets/{s}{s}", .{ stem, format });
                try asset_paths.append(gpa, run_shadercross.addOutputFileArg(out_path));
            }
        }
    }

    if (b.lazyDependency("lz4", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        exe.linkLibrary(dep.artifact("lz4"));
    }

    if (b.lazyDependency("stb_image", .{
        .target = target,
        .optimize = optimize,
        .use_llvm = use_llvm,
    })) |dep| {
        exe.linkLibrary(dep.artifact("stb-image"));
    }

    if (b.lazyDependency("nuklear", .{
        .target = target,
        .optimize = optimize,
        .use_llvm = use_llvm,
    })) |dep| {
        exe.linkLibrary(dep.artifact("nuklear"));
    }

    try copyAssets(b, gpa, &asset_paths);

    if (b.lazyDependency("assets_pack_generator", .{
        .target = target,
        .optimize = optimize,
        .use_llvm = use_llvm,
    })) |dep| {
        const run_asset_pack_gen =
            b.addRunArtifact(dep.artifact("assets-pack-generator"));

        const out_path = try std.fs.path.join(gpa, &.{ b.install_path, "assets" });
        defer gpa.free(out_path);
        const out = run_asset_pack_gen.addOutputDirectoryArg(out_path);
        for (asset_paths.items) |path| {
            run_asset_pack_gen.addFileArg(path);
        }

        b.getInstallStep().dependOn(&b.addInstallDirectory(.{
            .source_dir = out,
            .install_dir = .prefix,
            .install_subdir = "assets",
        }).step);
    }

    const test_step = b.step("test", "Run unit tests");

    const tests = b.addTest(.{
        .name = "tests",
        .root_module = root,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    b.installArtifact(exe);
    b.getInstallStep().dependOn(test_step);

    const run_tests = b.addRunArtifact(tests);
    test_step.dependOn(&run_tests.step);
}

fn getShaderFiles(gpa: Allocator) ![]const []const u8 {
    var cwd = std.fs.cwd();
    var arr: std.ArrayList([]const u8) = .empty;
    errdefer arr.deinit(gpa);

    var dir = try cwd.openDir("assets/shaders", .{ .iterate = true });
    defer dir.close();
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) {
            continue;
        }

        const name = try gpa.dupe(u8, entry.name);
        errdefer gpa.free(name);
        try arr.append(gpa, name);
    }
    return try arr.toOwnedSlice(gpa);
}

fn copyAssets(
    b: *std.Build,
    gpa: Allocator,
    arr: *std.ArrayList(std.Build.LazyPath),
) !void {
    var cwd = std.fs.cwd();
    const subdirs = &[_][]const u8{"textures"};
    for (subdirs) |subdir| {
        const dir_path = b.fmt("assets/{s}", .{subdir});
        var dir = try cwd.openDir(dir_path, .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        while (try it.next()) |entry| {
            if (entry.kind != .file) {
                continue;
            }

            const in_path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
            defer gpa.free(in_path);

            const run_cp = b.addSystemCommand(&.{"cp"});
            run_cp.addFileArg(b.path(in_path));

            const out_path = b.fmt("assets/{s}", .{entry.name});
            try arr.append(gpa, run_cp.addOutputFileArg(out_path));
        }
    }
}
