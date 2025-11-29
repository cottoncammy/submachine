const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "use_llvm",
        \\Whether to build with the LLVM backend
    ) orelse true;

    const root = b.createModule(.{
        .root_source_file = b.path("main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "assets-pack-generator",
        .root_module = root,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    exe.linkLibC();

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

    b.installArtifact(exe);
}
