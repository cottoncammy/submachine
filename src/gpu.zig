const std = @import("std");
const log = std.log.scoped(.gpu);
const Allocator = std.mem.Allocator;

const root = @import("root.zig");
const c = root.c;
const State = root.State;
const AssetsState = @import("AssetsState.zig");
const ShaderInfo = AssetsState.ShaderInfo;
const ShaderIndex = AssetsState.ShaderIndex;

const shader_stages = [_]c_uint{
    c.SDL_GPU_SHADERSTAGE_VERTEX,
    c.SDL_GPU_SHADERSTAGE_FRAGMENT,
};

pub fn createDevice() !*c.SDL_GPUDevice {
    const device_flags = c.SDL_GPU_SHADERFORMAT_SPIRV;
    return c.SDL_CreateGPUDevice(device_flags, true, null) orelse {
        log.err("Failed to create GPU device: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    };
}

pub fn createShader(
    gpa: Allocator,
    device: *c.SDL_GPUDevice,
    shaderidx: ShaderIndex,
    assets_state: *AssetsState,
) !*c.SDL_GPUShader {
    const format = c.SDL_GPU_SHADERFORMAT_SPIRV;
    const code = try assets_state.readShaderCode(gpa, shaderidx, format);
    defer gpa.free(code);

    const parsed = try assets_state.readShaderJson(gpa, shaderidx);
    defer parsed.deinit();
    const json = parsed.value;

    const createinfo = std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, .{
        .code_size = code.len,
        .code = code.ptr,
        .entrypoint = "main",
        .format = format,
        .stage = shader_stages[@intFromEnum(shaderidx) & 0x1],
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
