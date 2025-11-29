// Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
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
        .name = "spirv-cross",
        .root_module = root,
        .use_llvm = use_llvm,
        .use_lld = use_llvm,
    });

    lib.linkLibC();
    lib.linkLibCpp();

    const path = b.path("../../vendor/SDL_shadercross/external/SPIRV-Cross");
    lib.installHeadersDirectory(path, "", .{ .include_extensions = &.{".h"} });
    root.addIncludePath(path);
    root.addCSourceFiles(.{
        .root = path,
        .flags = &.{
            "-DSPIRV_CROSS_C_API_GLSL=1",
            "-DSPIRV_CROSS_C_API_HLSL=1",
            "-DSPIRV_CROSS_C_API_MSL=1",
        },
        .files = &.{
            "spirv_cross.cpp",
            "spirv_parser.cpp",
            "spirv_cross_parsed_ir.cpp",
            "spirv_cfg.cpp",
            "spirv_cross_c.cpp",
            "spirv_glsl.cpp",
            "spirv_hlsl.cpp",
            "spirv_msl.cpp",
        },
    });

    b.installArtifact(lib);
}
