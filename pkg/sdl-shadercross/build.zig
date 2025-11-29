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

    if (b.lazyDependency("sdl", .{
        .target = target,
        .optimize = optimize,
    })) |dep| {
        lib.linkLibrary(dep.artifact("SDL3"));
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

    const path = b.path("../../vendor/SDL_shadercross");

    lib.installHeader(
        try path.join(
            b.allocator,
            "include/SDL3_shadercross/SDL_shadercross.h",
        ),
        "SDL3_shadercross/SDL_shadercross.h",
    );

    lib_root.addIncludePath(try path.join(b.allocator, "include"));
    lib_root.addCSourceFiles(.{
        .root = path,
        .flags = &.{"-DSDL_SHADERCROSS_DXC=1"},
        .files = &.{"src/SDL_shadercross.c"},
    });

    const sdl_path = b.path("../../vendor/SDL/include/SDL3");
    lib.installHeadersDirectory(sdl_path, "SDL3", .{});
    lib_root.addIncludePath(sdl_path);

    b.installArtifact(lib);

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
    exe_root.addCSourceFile(.{ .file = try path.join(b.allocator, "src/cli.c") });
    b.installArtifact(exe);
}
