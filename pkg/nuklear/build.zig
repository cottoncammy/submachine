const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "use_llvm",
        \\Whether to build with the LLVM backend
    ) orelse true;

    const root = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "nuklear",
        .root_module = root,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    lib.linkLibC();

    if (b.lazyDependency("nuklear", .{
        .target = target,
        .optimize = optimize,
    })) |upstream| {
        lib.installHeader(upstream.path("src/nuklear.h"), "nuklear.h");
        root.addIncludePath(upstream.path("src"));
        root.addCSourceFile(.{ .file = b.path("main.c") });
    }

    b.installArtifact(lib);
}
