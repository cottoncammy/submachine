const std = @import("std");
const log = std.log.scoped(.gpu);
const Allocator = std.mem.Allocator;

const c = @import("root.zig").c;
const AssetsState = @import("AssetsState.zig");
const ShaderInfo = AssetsState.ShaderInfo;
const ShaderIndex = AssetsState.ShaderIndex;

pub fn createShader(
    gpa: Allocator,
    device: *c.SDL_GPUDevice,
    idx: ShaderIndex,
    assets_state: *AssetsState,
) !*c.SDL_GPUShader {
    const format = c.SDL_GPU_SHADERFORMAT_SPIRV;
    const code = try assets_state.readShaderCode(idx, format);
    defer gpa.free(code);

    const json = try assets_state.readShaderJson(idx);

    const createinfo = std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, .{
        .code_size = code.len,
        .code = code.ptr,
        .entrypoint = "main",
        .format = format,
        .stage = getShaderStage(idx),
        .num_samplers = json.samplers,
        .num_storage_textures = json.storage_textures,
        .num_storage_buffers = json.storage_buffers,
        .num_uniform_buffers = json.uniform_buffers,
    });

    return c.SDL_CreateGPUShader(device, &createinfo) orelse {
        log.err("Failed to create GPU shader: {s}", .{c.SDL_GetError()});
        return error.GPUShader;
    };
}

pub fn createPipeline(
    device: *c.SDL_GPUDevice,
    createinfo: *c.SDL_GPUGraphicsPipelineCreateInfo,
) !*c.SDL_GPUGraphicsPipeline {
    return c.SDL_CreateGPUGraphicsPipeline(device, createinfo) orelse {
        log.err("Failed to create GPU pipeline: {s}", .{c.SDL_GetError()});
        return error.GPUPipeline;
    };
}

pub fn createBuffer(
    device: *c.SDL_GPUDevice,
    createinfo: *const c.SDL_GPUBufferCreateInfo,
) !*c.SDL_GPUBuffer {
    return c.SDL_CreateGPUBuffer(device, createinfo) orelse {
        log.err("Failed to create GPU buffer: {s}", .{c.SDL_GetError()});
        return error.GPUBuffer;
    };
}

pub fn createTexture(
    device: *c.SDL_GPUDevice,
    createinfo: *const c.SDL_GPUTextureCreateInfo,
) !*c.SDL_GPUTexture {
    return c.SDL_CreateGPUTexture(device, createinfo) orelse {
        log.err("Failed to create GPU texture: {s}", .{c.SDL_GetError()});
        return error.GPUTexture;
    };
}

pub fn createSampler(
    device: *c.SDL_GPUDevice,
    createinfo: *const c.SDL_GPUSamplerCreateInfo,
) !*c.SDL_GPUSampler {
    return c.SDL_CreateGPUSampler(device, createinfo) orelse {
        log.err("Failed to create GPU sampler: {s}", .{c.SDL_GetError()});
        return error.GPUSampler;
    };
}

pub fn createTransferBuffer(
    device: *c.SDL_GPUDevice,
    createinfo: *const c.SDL_GPUTransferBufferCreateInfo,
) !*c.SDL_GPUTransferBuffer {
    return c.SDL_CreateGPUTransferBuffer(device, createinfo) orelse {
        log.err("Failed to create GPU transfer buffer: {s}", .{c.SDL_GetError()});
        return error.GPUBuffer;
    };
}

pub fn acquireCommandBuffer(device: *c.SDL_GPUDevice) !?*c.SDL_GPUCommandBuffer {
    return c.SDL_AcquireGPUCommandBuffer(device) orelse {
        log.err("Failed to acquire command buffer: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    };
}

pub fn submitCommandBuffer(cmdbuf: ?*c.SDL_GPUCommandBuffer) !void {
    if (!c.SDL_SubmitGPUCommandBuffer(cmdbuf)) {
        log.err("Failed to submit command buffer: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    }
}

pub fn beginCopyPass(cmdbuf: ?*c.SDL_GPUCommandBuffer) !?*c.SDL_GPUCopyPass {
    return c.SDL_BeginGPUCopyPass(cmdbuf) orelse {
        log.err("Failed to begin copy pass: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    };
}

fn getShaderStage(idx: ShaderIndex) c_uint {
    return switch (idx) {
        .sprite_vert => c.SDL_GPU_SHADERSTAGE_VERTEX,
        .solid_color_frag => c.SDL_GPU_SHADERSTAGE_FRAGMENT,
    };
}
