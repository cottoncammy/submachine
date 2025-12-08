const std = @import("std");
const Allocator = std.mem.Allocator;

const root = @import("root.zig");
const c = root.c;
const gpu = @import("gpu.zig");
const hash_map = @import("hash_map.zig");
const Material = @import("Material.zig");
const AssetsState = @import("AssetsState.zig");
const ShaderIndex = AssetsState.ShaderIndex;
const TextureIndex = AssetsState.TextureIndex;

const max_textures_len = AssetsState.max_textures_len;
const max_materials_len = 1;

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

const MaterialIndex = enum {
    sprite,
};

const Self = @This();

arena: std.heap.ArenaAllocator,
assets_state: *AssetsState,

device: *c.SDL_GPUDevice,
pipelines: std.HashMapUnmanaged(
    PipelineDesc,
    *c.SDL_GPUGraphicsPipeline,
    hash_map.Context(PipelineDesc),
    std.hash_map.default_max_load_percentage,
),
textures: []?*c.SDL_GPUTexture,
samplers: std.HashMapUnmanaged(
    SamplerDesc,
    *c.SDL_GPUSampler,
    hash_map.Context(SamplerDesc),
    std.hash_map.default_max_load_percentage,
),
materials: []?*Material,

pub fn init(gpa: Allocator, assets_state: *AssetsState, device: *c.SDL_GPUDevice) !Self {
    var self: Self = .{
        .arena = .init(gpa),
        .assets_state = assets_state,
        .device = device,
        .pipelines = .empty,
        .textures = &.{},
        .samplers = .empty,
        .materials = &.{},
    };

    const allocator = self.arena.allocator();
    self.textures = try allocator.alloc(?*c.SDL_GPUTexture, max_textures_len);
    @memset(self.textures, null);
    self.materials = try allocator.alloc(?*Material, max_materials_len);
    @memset(self.materials, null);
    return self;
}

pub fn deinit(self: *Self) void {
    var samplers = self.samplers.valueIterator();
    while (samplers.next()) |value| c.SDL_ReleaseGPUSampler(self.device, value.*);
    for (self.textures) |texture| c.SDL_ReleaseGPUTexture(self.device, texture);

    var pipelines = self.pipelines.valueIterator();
    while (pipelines.next()) |value| c.SDL_ReleaseGPUGraphicsPipeline(self.device,
value.*);
    self.arena.deinit();
}

pub fn getOrCreatePipeline(
    self: *Self,
    desc: PipelineDesc,
) !*c.SDL_GPUGraphicsPipeline {
    const gpa = self.arena.allocator();

    const result = try self.pipelines.getOrPut(gpa, desc);
    if (!result.found_existing) {
        const vert_shader = try gpu.createShader(gpa, self.device, desc.vert_shader,
self.assets_state);
        defer c.SDL_ReleaseGPUShader(self.device, vert_shader);
        const frag_shader = try gpu.createShader(gpa, self.device, desc.frag_shader,
self.assets_state);
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
    textureidx: TextureIndex,
) !*c.SDL_GPUTexture {
    const idx = @intFromEnum(textureidx);
    std.debug.assert(self.textures.len > idx);

    if (self.textures[idx] == null) {
        var width: c_int = 0;
        var height: c_int = 0;
        var channels: c_int = 0;
        var buf = try self.assets_state.readTexture(
            self.arena.allocator(),
            textureidx,
            &width,
            &height,
            &channels,
        );

        defer c.stbi_image_free(buf);

        const createinfo = c.SDL_GPUTextureCreateInfo{
            .type = c.SDL_GPU_TEXTURETYPE_2D,
            .format = c.SDL_GPU_TEXTUREFORMAT_R8G8B8A8_UNORM,
            .width = @intCast(width),
            .height = @intCast(height),
            .layer_count_or_depth = 1,
            .num_levels = 1,
            .usage = c.SDL_GPU_TEXTUREUSAGE_SAMPLER,
        };

        self.textures[idx] = try gpu.createTexture(self.device, &createinfo);
        errdefer c.SDL_ReleaseGPUTexture(self.device, self.textures[idx]);

        const transfer_buf_info = c.SDL_GPUTransferBufferCreateInfo{
            .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            .size = @intCast(width * height * 4),
        };

        const transfer_buf = try gpu.createTransferBuffer(self.device,
&transfer_buf_info);
        defer c.SDL_ReleaseGPUTransferBuffer(self.device, transfer_buf);

        const transfer_data: [*]u8 =
            @ptrCast(c.SDL_MapGPUTransferBuffer(
                self.device,
                transfer_buf,
                false,
            ));

        const len: usize = @intCast(width * height * channels);
        @memcpy(transfer_data[0..len], buf[0..len]);
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
                .texture = self.textures[idx].?,
                .w = @intCast(width),
                .h = @intCast(height),
                .d = 1,
            },
            false,
        );

        c.SDL_EndGPUCopyPass(copypass);
        try gpu.submitCommandBuffer(cmdbuf);
    }

    return self.textures[idx].?;
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

pub fn createMaterial(
    self: *Self,
    material_idx: MaterialIndex,
    pipeline: PipelineDesc,
    opt_texture: ?TextureIndex,
    opt_sampler: ?SamplerDesc,
    uniform_buf_len: usize,
) !void {
    const idx = @intFromEnum(material_idx);
    std.debug.assert(self.materials.len > idx);
    const slot = &self.materials[idx];
    std.debug.assert(slot.* == null);

    const gpa = self.arena.allocator();
    const material = try gpa.create(Material);
    material.* = std.mem.zeroInit(Material, .{
        .pipeline = try self.getOrCreatePipeline(pipeline),
        .uniform_buf = try gpa.alloc(u8, uniform_buf_len),
    });

    if (opt_texture) |texture| material.*.texture = try self.getOrCreateTexture(texture);
    if (opt_sampler) |sampler| material.*.sampler = try self.getOrCreateSampler(sampler);

    slot.* = material;
}

pub fn getMaterial(self: *Self, material_idx: MaterialIndex) !*Material {
    const idx = @intFromEnum(material_idx);
    std.debug.assert(self.materials.len > idx);
    const material = self.materials[idx];
    return material.?;
}

pub fn push() void {}

pub fn drain() void {}

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
