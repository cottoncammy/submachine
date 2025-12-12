const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const use_llvm = b.option(bool, "use_llvm",
        \\Whether to build with the LLVM backend
    ) orelse true;

    const lib_root = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name = "sdl-shadercross",
        .root_module = lib_root,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    lib.linkLibC();

    const exe_root = b.createModule(.{
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "sdl-shadercross-cli",
        .root_module = exe_root,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    exe.linkLibrary(lib);

    if (b.lazyDependency("sdl_shadercross", .{
        .target = target,
        .optimize = optimize,
    })) |upstream| {
        lib.installHeader(
            upstream.path("include/SDL3_shadercross/SDL_shadercross.h"),
            "SDL3_shadercross/SDL_shadercross.h",
        );

        lib_root.addIncludePath(upstream.path("include"));
        lib_root.addCSourceFile(.{
            .flags = &.{"-DSDL_SHADERCROSS_DXC=1"},
            .file = upstream.path("src/SDL_shadercross.c"),
        });

        exe_root.addCSourceFile(.{ .file = upstream.path("src/cli.c") });
    }

    if (b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        lib.linkLibrary(dep.artifact("SDL3"));
    }

    if (b.lazyDependency("sdl_upstream", .{
        .target = target,
        .optimize = optimize,
    })) |upstream| {
        lib.installHeadersDirectory(upstream.path("include/SDL3"), "SDL3", .{});
        lib_root.addIncludePath(upstream.path("include"));
    }

    if (b.lazyDependency("spirv_cross", .{
        .target = target,
        .optimize = optimize,
        .use_llvm = use_llvm,
    })) |dep| {
        lib.linkLibrary(dep.artifact("spirv-cross"));
    }

    if (b.systemIntegrationOption("dxcompiler", .{})) {
        lib.linkSystemLibrary2("dxcompiler", .{ .use_pkg_config = .no });
    }

    b.installArtifact(lib);
    b.installArtifact(exe);
}
