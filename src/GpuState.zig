const std = @import("std");
const log = std.log.scoped(.gpu_state);
const Allocator = std.mem.Allocator;

const c = @import("root.zig").c;
const gpu = @import("gpu.zig");
const hash_map = @import("hash_map.zig");
const Material = @import("Material.zig");
const AssetsState = @import("AssetsState.zig");
const ShaderIndex = AssetsState.ShaderIndex;
const TextureIndex = AssetsState.TextureIndex;
const MaterialIndex = AssetsState.MaterialIndex;

pub const PipelineDesc = struct {
    vert_shader: ShaderIndex,
    frag_shader: ShaderIndex,
    vertex_input_state: c.SDL_GPUVertexInputState,
    target_info: c.SDL_GPUGraphicsPipelineTargetInfo,
    primitive_type: c.SDL_GPUPrimitiveType,
    rasterizer_state: c.SDL_GPURasterizerState,
    multisample_state: c.SDL_GPUMultisampleState,
    depth_stencil_state: c.SDL_GPUDepthStencilState,
    props: c.SDL_PropertiesID,
};

pub const SamplerDesc = struct {
    min_filter: c.SDL_GPUFilter,
    mag_filter: c.SDL_GPUFilter,
    mipmap_mode: c.SDL_GPUSamplerMipmapMode,
    address_mode_u: c.SDL_GPUSamplerAddressMode,
    address_mode_v: c.SDL_GPUSamplerAddressMode,
    address_mode_w: c.SDL_GPUSamplerAddressMode,
    mip_lod_bias: f32,
    max_anisotropy: f32,
    compare_op: c.SDL_GPUCompareOp,
    min_lod: f32,
    max_lod: f32,
    enable_anisotropy: bool,
    enable_compare: bool,
    props: c.SDL_PropertiesID,
};

pub const MaterialDesc = struct {
    idx: MaterialIndex,
    pipeline: PipelineDesc,
    texture: ?TextureIndex,
    sampler: ?SamplerDesc,
};

const TextureSlot = union(enum) {
    empty,
    ready: *c.SDL_GPUTexture,
};

const MaterialSlot = union(enum) {
    empty,
    ready: Material,
};

const Self = @This();

arena: std.heap.ArenaAllocator,
window: *c.SDL_Window,
device: *c.SDL_GPUDevice,
assets_state: *AssetsState,
pipelines: std.HashMapUnmanaged(
    PipelineDesc,
    *c.SDL_GPUGraphicsPipeline,
    hash_map.Context(PipelineDesc),
    std.hash_map.default_max_load_percentage,
),
textures: std.EnumArray(TextureIndex, TextureSlot),
samplers: std.HashMapUnmanaged(
    SamplerDesc,
    *c.SDL_GPUSampler,
    hash_map.Context(SamplerDesc),
    std.hash_map.default_max_load_percentage,
),
materials: std.EnumArray(MaterialIndex, MaterialSlot),

pub fn init(
    gpa: Allocator,
    window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,
    assets_state: *AssetsState,
) !Self {
    return .{
        .arena = .init(gpa),
        .window = window,
        .device = device,
        .assets_state = assets_state,
        .pipelines = .empty,
        .textures = std.EnumArray(TextureIndex, TextureSlot).initFill(.empty),
        .samplers = .empty,
        .materials = std.EnumArray(MaterialIndex, MaterialSlot).initFill(.empty),
    };
}

pub fn deinit(self: *Self) void {
    var samplers = self.samplers.valueIterator();
    while (samplers.next()) |sampler| {
        c.SDL_ReleaseGPUSampler(self.device, sampler.*);
    }

    for (std.enums.values(TextureIndex)) |idx| {
        switch (self.textures.get(idx)) {
            .ready => |texture| {
                c.SDL_ReleaseGPUTexture(self.device, texture);
            },
            .empty => {},
        }
    }

    var pipelines = self.pipelines.valueIterator();
    while (pipelines.next()) |pipeline| {
        c.SDL_ReleaseGPUGraphicsPipeline(self.device, pipeline.*);
    }

    self.arena.deinit();
}

pub fn getOrCreatePipeline(
    self: *Self,
    desc: PipelineDesc,
) !*c.SDL_GPUGraphicsPipeline {
    const gpa = self.arena.allocator();
    const result = try self.pipelines.getOrPut(gpa, desc);
    if (!result.found_existing) {
        const vert_shader = try gpu.createShader(gpa, self.device, desc.vert_shader, self.assets_state);
        defer c.SDL_ReleaseGPUShader(self.device, vert_shader);
        const frag_shader = try gpu.createShader(gpa, self.device, desc.frag_shader, self.assets_state);
        defer c.SDL_ReleaseGPUShader(self.device, frag_shader);

        var createinfo = getPipelineCreateInfo(desc);
        createinfo.vertex_shader = vert_shader;
        createinfo.fragment_shader = frag_shader;

        const pipeline = try gpu.createPipeline(self.device, &createinfo);
        result.value_ptr.* = pipeline;
    }

    return result.value_ptr.*;
}

pub fn getOrCreateTexture(
    self: *Self,
    idx: TextureIndex,
) !*c.SDL_GPUTexture {
    const slot = self.textures.getPtr(idx);

    switch (slot.*) {
        .ready => |texture| return texture,
        .empty => {},
    }

    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;

    var texture_buf = try self.assets_state.readTexture(
        idx,
        &width,
        &height,
        &channels,
    );

    defer c.stbi_image_free(texture_buf);

    const createinfo = c.SDL_GPUTextureCreateInfo{
        .type = c.SDL_GPU_TEXTURETYPE_2D,
        .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
        .width = @intCast(width),
        .height = @intCast(height),
        .layer_count_or_depth = 1,
        .num_levels = 1,
        .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
    };

    const texture = try gpu.createTexture(self.device, &createinfo);
    errdefer c.SDL_ReleaseGPUTexture(self.device, texture);

    const transfer_buf_info = c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @intCast(width * height * channels),
    };

    const transfer_buf = try gpu.createTransferBuffer(self.device, &transfer_buf_info);
    defer c.SDL_ReleaseGPUTransferBuffer(self.device, transfer_buf);

    const addr = c.SDL_MapGPUTransferBuffer(
        self.device,
        transfer_buf,
        false,
    ) orelse {
        log.err("Failed to map GPU transfer buffer: {s}", .{c.SDL_GetError()});
        return error.GPUBuffer;
    };

    const transfer_data: [*]u8 = @ptrCast(@alignCast(addr));

    const len: usize = @intCast(width * height * channels);
    @memcpy(transfer_data[0..len], texture_buf[0..len]);
    c.SDL_UnmapGPUTransferBuffer(self.device, transfer_buf);

    const cmdbuf = try gpu.acquireCommandBuffer(self.device);
    const copypass = try gpu.beginCopyPass(cmdbuf);

    c.SDL_UploadToGPUTexture(
        copypass,
        &.{
            .transfer_buffer = transfer_buf,
            .offset = 0,
        },
        &.{
            .texture = texture,
            .w = @intCast(width),
            .h = @intCast(height),
            .d = 1,
        },
        false,
    );

    c.SDL_EndGPUCopyPass(copypass);
    try gpu.submitCommandBuffer(cmdbuf);

    slot.* = .{ .ready = texture };
    return texture;
}

pub fn getOrCreateSampler(
    self: *Self,
    desc: SamplerDesc,
) !*c.SDL_GPUSampler {
    const result = try self.samplers.getOrPut(self.arena.allocator(), desc);
    if (!result.found_existing) {
        const createinfo = getSamplerCreateInfo(desc);
        const sampler = try gpu.createSampler(self.device, &createinfo);
        result.value_ptr.* = sampler;
    }
    return result.value_ptr.*;
}

pub fn getMaterial(self: *Self, idx: MaterialIndex) !Material {
    const slot = self.materials.getPtr(idx);
    return switch (slot.*) {
        .ready => |material| material,
        .empty => error.NoMaterial,
    };
}

pub fn createMaterial(
    self: *Self,
    comptime Uniforms: type,
    idx: MaterialIndex,
) !void {
    const info = self.assets_state.getMaterialInfo(idx);
    const json = info.json;

    var desc = std.mem.zeroInit(MaterialDesc, .{ .idx = idx });

    var pipeline_desc = std.mem.zeroInit(PipelineDesc, .{
        .vert_shader = try AssetsState.getShaderIndex(json.vertex_shader),
        .frag_shader = try AssetsState.getShaderIndex(json.fragment_shader),
    });

    if (json.texture) |texture| {
        desc.texture = try AssetsState.getTextureIndex(texture);
    }

    if (json.blend) |blend| switch (blend) {
        .alpha => {
            pipeline_desc.target_info = std.mem.zeroInit(
                c.SDL_GPUGraphicsPipelineTargetInfo,
                .{
                    .num_color_targets = 1,
                    .color_target_descriptions = &[_]c.SDL_GPUColorTargetDescription{
                        .{
                            .format = c.SDL_GetGPUSwapchainTextureFormat(self.device, self.window),
                            .blend_state = .{
                                .enable_blend = true,
                                .alpha_blend_op = c.SDL_GPU_BLENDOP_ADD,
                                .color_blend_op = c.SDL_GPU_BLENDOP_ADD,
                                .src_color_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
                                .src_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_SRC_ALPHA,
                                .dst_color_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                                .dst_alpha_blendfactor = c.SDL_GPU_BLENDFACTOR_ONE_MINUS_SRC_ALPHA,
                            },
                        },
                    },
                },
            );
        },
    };

    if (json.sampler) |sampler| switch (sampler) {
        .nearest => {
            desc.sampler = std.mem.zeroInit(SamplerDesc, .{
                .min_filter = c.SDL_GPU_FILTER_NEAREST,
                .mag_filter = c.SDL_GPU_FILTER_NEAREST,
                .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
                .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
                .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
                .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
            });
        },
    };

    desc.pipeline = pipeline_desc;
    try self.createMaterialFromDesc(Uniforms, desc);
}

fn getPipelineCreateInfo(desc: PipelineDesc) c.SDL_GPUGraphicsPipelineCreateInfo {
    var createinfo = std.mem.zeroes(c.SDL_GPUGraphicsPipelineCreateInfo);
    inline for (@typeInfo(@TypeOf(desc)).@"struct".fields) |field| {
        if (comptime !std.mem.eql(u8, field.name, "vert_shader") and
            !std.mem.eql(u8, field.name, "frag_shader"))
        {
            @field(createinfo, field.name) = @field(desc, field.name);
        }
    }
    return createinfo;
}

fn getSamplerCreateInfo(desc: SamplerDesc) c.SDL_GPUSamplerCreateInfo {
    var createinfo = std.mem.zeroes(c.SDL_GPUSamplerCreateInfo);
    inline for (@typeInfo(@TypeOf(desc)).@"struct".fields) |field| {
        @field(createinfo, field.name) = @field(desc, field.name);
    }
    return createinfo;
}

fn createMaterialFromDesc(
    self: *Self,
    comptime Uniforms: type,
    desc: MaterialDesc,
) !void {
    const slot = self.materials.getPtr(desc.idx);

    switch (slot.*) {
        .ready => return error.DuplicateMaterial,
        .empty => {},
    }

    const gpa = self.arena.allocator();
    var material = std.mem.zeroInit(Material, .{
        .pipeline = try self.getOrCreatePipeline(desc.pipeline),
        .uniform_buf = try gpa.alloc(u8, @sizeOf(Uniforms)),
    });

    if (desc.texture) |texture| {
        material.texture = try self.getOrCreateTexture(texture);
    }

    if (desc.sampler) |sampler| {
        material.sampler = try self.getOrCreateSampler(sampler);
    }

    slot.* = .{ .ready = material };
}
