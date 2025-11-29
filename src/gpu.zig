const std = @import("std");
const log = std.log.scoped(.gpu);
const Allocator = std.mem.Allocator;

const root = @import("root.zig");
const c = root.c;
const State = root.State;
const AssetsState = root.AssetsState;
const ShaderInfo = AssetsState.ShaderInfo;
const ShaderIndex = AssetsState.ShaderIndex;

const shader_stages = [_]c_uint{
    c.SDL_GPU_SHADERSTAGE_VERTEX,
    c.SDL_GPU_SHADERSTAGE_FRAGMENT,
};

const ShaderJson = struct {
    samplers: c_uint,
    storage_textures: c_uint,
    storage_buffers: c_uint,
    uniform_buffers: c_uint,
};

pub fn createDevice() !*c.SDL_GPUDevice {
    const device_flags = c.SDL_GPU_SHADERFORMAT_SPIRV;
    return c.SDL_CreateGPUDevice(device_flags, true, null) orelse {
        log.err("Failed to create GPU device: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    };
}

pub fn createShader(
    state: *State,
    gpa: Allocator,
    shaderidx: ShaderIndex,
) !*c.SDL_GPUShader {
    const assets_state = state.assets_state;
    const idx = @intFromEnum(shaderidx) >> 1;
    std.debug.assert(assets_state.shaders_lut.len > idx);
    const shaderinfo = assets_state.shaders_lut[idx].?;

    // code
    var code_offset: usize = 0;
    var code_len: usize = 0;
    var code_comp_len: usize = 0;
    var format: c_uint = c.SDL_GPU_SHADERFORMAT_INVALID;

    const formats = c.SDL_GetGPUShaderFormats(state.device);
    if (formats & c.SDL_GPU_SHADERFORMAT_SPIRV != 0) {
        code_offset = shaderinfo.spv_offset;
        code_len = shaderinfo.spv_len;
        code_comp_len = shaderinfo.spv_comp_len;
        format = c.SDL_GPU_SHADERFORMAT_SPIRV;
    } else {
        unreachable;
    }

    const code = try gpa.allocSentinel(u8, code_len, 0);
    defer gpa.free(code);

    const result = c.LZ4_decompress_safe(
        @ptrCast(assets_state.file_map[code_offset .. code_offset + code_comp_len]),
        code.ptr,
        @intCast(code_comp_len),
        @intCast(code_len),
    );
    if (result == 0) {
        log.err("Failed to decompress shader code", .{});
        return error.LZ4Decompress;
    }

    const parsed = try parseShaderJson(assets_state, gpa, shaderinfo);
    defer parsed.deinit();
    const json = parsed.value;

    const createinfo = std.mem.zeroInit(c.SDL_GPUShaderCreateInfo, .{
        .code_size = code_len,
        .code = code.ptr,
        .entrypoint = "main",
        .format = format,
        .stage = shader_stages[@intFromEnum(shaderidx) & 0x1],
        .num_samplers = json.samplers,
        .num_storage_textures = json.storage_textures,
        .num_storage_buffers = json.storage_buffers,
        .num_uniform_buffers = json.uniform_buffers,
    });

    return c.SDL_CreateGPUShader(state.device, &createinfo) orelse {
        log.err("Failed to create GPU shader: {s}", .{c.SDL_GetError()});
        return error.GPUShader;
    };
}

fn parseShaderJson(
    assets_state: *AssetsState,
    gpa: Allocator,
    shaderinfo: *ShaderInfo,
) !std.json.Parsed(ShaderJson) {
    const offset = shaderinfo.json_offset;
    const len = shaderinfo.json_len;
    const comp_len = shaderinfo.json_comp_len;

    const buf = try gpa.allocSentinel(u8, len, 0);
    defer gpa.free(buf);

    const result = c.LZ4_decompress_safe(
        @ptrCast(assets_state.file_map[offset .. offset + comp_len]),
        buf.ptr,
        @intCast(comp_len),
        @intCast(len),
    );
    if (result == 0) {
        log.err("Failed to decompress shader json", .{});
        return error.LZ4Decompress;
    }

    return try std.json.parseFromSlice(
        ShaderJson,
        gpa,
        buf,
        .{ .ignore_unknown_fields = true },
    );
}

pub fn createPipeline(
    state: *State,
    vert_shader: *c.SDL_GPUShader,
    frag_shader: *c.SDL_GPUShader,
    vert_input_state: c.SDL_GPUVertexInputState,
    target_info: c.SDL_GPUGraphicsPipelineTargetInfo,
    fill_mode: c.SDL_GPUFillMode,
) !*c.SDL_GPUGraphicsPipeline {
    const createinfo = std.mem.zeroInit(c.SDL_GPUGraphicsPipelineCreateInfo, .{
        .vertex_shader = vert_shader,
        .fragment_shader = frag_shader,
        .vertex_input_state = vert_input_state,
        .primitive_type = c.SDL_GPU_PRIMITIVETYPE_TRIANGLELIST,
        .rasterizer_state = .{ .fill_mode = fill_mode },
        .target_info = target_info,
    });

    return c.SDL_CreateGPUGraphicsPipeline(state.device, &createinfo) orelse {
        log.err("Failed to create GPU pipeline: {s}", .{c.SDL_GetError()});
        return error.GPUPipeline;
    };
}

pub fn createBuffer(
    state: *State,
    flags: c.SDL_GPUBufferUsageFlags,
    size: u32,
) !*c.SDL_GPUBuffer {
    const createinfo = std.mem.zeroInit(c.SDL_GPUBufferCreateInfo, .{
        .usage = flags,
        .size = size,
    });

    return c.SDL_CreateGPUBuffer(state.device, &createinfo) orelse {
        log.err("Failed to create GPU buffer: {s}", .{c.SDL_GetError()});
        return error.GPUBuffer;
    };
}

pub fn createTexture(state: *State, width: u32, height: u32) !*c.SDL_GPUTexture {
    const createinfo = std.mem.zeroInit(c.SDL_GPUTextureCreateInfo, .{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .width = width,
        .height = height,
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
    });

    return c.SDL_CreateGPUTexture(state.device, &createinfo) orelse {
        log.err("Failed to create GPU texture: {s}", .{c.SDL_GetError()});
        return error.GPUTexture;
    };
}

pub fn createSampler(state: *State) !*c.SDL_GPUSampler {
    const createinfo = std.mem.zeroInit(c.SDL_GPUSamplerCreateInfo, .{
        .min_filter = c.SDL_GPU_FILTER_NEAREST,
        .mag_filter = c.SDL_GPU_FILTER_NEAREST,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
    });

    return c.SDL_CreateGPUSampler(state.device, &createinfo) orelse {
        log.err("Failed to create GPU sampler: {s}", .{c.SDL_GetError()});
        return error.GPUSampler;
    };
}

pub fn createTransferBuffer(
    state: *State,
    usage: c.SDL_GPUTransferBufferUsage,
    size: u32,
) !*c.SDL_GPUTransferBuffer {
    const createinfo = std.mem.zeroInit(c.SDL_GPUTransferBufferCreateInfo, .{
        .usage = usage,
        .size = size,
    });

    return c.SDL_CreateGPUTransferBuffer(state.device, &createinfo) orelse {
        log.err("Failed to create GPU transfer buffer: {s}", .{c.SDL_GetError()});
        return error.GPUBuffer;
    };
}
