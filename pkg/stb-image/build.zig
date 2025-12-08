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
        .name = "stb-image",
        .root_module = root,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    lib.linkLibC();

    lib.installHeader(b.path("stb_image.h"), "stb_image.h");
    root.addIncludePath(b.path(""));
    root.addCSourceFile(.{ .file = b.path("main.c") });

    b.installArtifact(lib);
}
