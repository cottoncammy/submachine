const std = @import("std");
const log = std.log.scoped(.root);

const gpu = @import("gpu.zig");
const mat4 = @import("mat4.zig");
const Camera = @import("Camera.zig");
const GpuState = @import("GpuState.zig");
const hash_map = @import("hash_map.zig");
const Material = @import("Material.zig");
const AssetsState = @import("AssetsState.zig");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("lz4.h");
    @cInclude("stb_image.h");
});

const PipelineDesc = GpuState.PipelineDesc;
const SamplerDesc = GpuState.SamplerDesc;

pub const State = struct {
    window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,
    assets_state: *AssetsState,
    gpu_state: *GpuState,
    storage_buf: *c.SDL_GPUBuffer,
    transfer_buf: *c.SDL_GPUTransferBuffer,
    camera: *Camera,
};

const Sprite = struct {
    pos: [3]f32,
    rotation: f32,
    color: [4]f32,
    size: [2]f32,
    padding: [2]f32,
};

const max_sprites = 10;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    const state = try allocator.create(State);
    defer allocator.destroy(state);

    // subsystems
    if (!c.SDL_SetAppMetadata("submachine", "0.1.0", "xyz.cottoncammy")) {
        log.err("Failed to set app metadata: {s}", .{c.SDL_GetError()});
        return error.SDLInit;
    }
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        log.err("Failed to initialize SDL: {s}", .{c.SDL_GetError()});
        return error.SDLInit;
    }
    defer c.SDL_Quit();

    // window
    _ = c.SDL_WINDOWPOS_CENTERED;
    const window_flags = c.SDL_WINDOW_RESIZABLE;
    state.window = c.SDL_CreateWindow("submachine", 960, 600, window_flags) orelse {
        log.err("Failed to create window: {s}", .{c.SDL_GetError()});
        return error.SDLInit;
    };
    defer c.SDL_DestroyWindow(state.window);

    // device
    state.device = try gpu.createDevice();
    defer c.SDL_DestroyGPUDevice(state.device);

    if (!c.SDL_ClaimWindowForGPUDevice(state.device, state.window)) {
        log.err("Failed to claim window for GPU device: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    }
    defer c.SDL_ReleaseWindowFromGPUDevice(state.device, state.window);

    // assets state
    state.assets_state = try allocator.create(AssetsState);
    defer allocator.destroy(state.assets_state);
    state.assets_state.* = try AssetsState.init(allocator);
    defer state.assets_state.deinit(allocator);

    try state.assets_state.parseAssetsManifest(allocator);
    defer state.assets_state.munmapAssetsPack();

    // gpu state
    state.gpu_state = try allocator.create(GpuState);
    defer allocator.destroy(state.gpu_state);
    state.gpu_state.* = try GpuState.init(allocator, state.assets_state, state.device);
    defer state.gpu_state.deinit();

    // pipeline
    var pipeline_desc = std.mem.zeroInit(PipelineDesc, .{
        .vert_shader = .sprite_vert,
        .frag_shader = .solid_color_frag,
    });

    pipeline_desc.target_info = std.mem.zeroInit(c.SDL_GPUGraphicsPipelineTargetInfo, .{
        .num_color_targets = 1,
        .color_target_descriptions = &[_]c.SDL_GPUColorTargetDescription{
            .{
                .format = c.SDL_GetGPUSwapchainTextureFormat(state.device, state.window),
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
    });

    // buffers
    const storage_buf_info = c.SDL_GPUBufferCreateInfo{
        .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
        .size = @sizeOf(Sprite) * 1,
    };

    state.storage_buf = try gpu.createBuffer(state.device, &storage_buf_info);
    defer c.SDL_ReleaseGPUBuffer(state.device, state.storage_buf);

    const transfer_buf_info = c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @sizeOf(Sprite) * 1,
    };

    state.transfer_buf = try gpu.createTransferBuffer(state.device, &transfer_buf_info);
    defer c.SDL_ReleaseGPUTransferBuffer(state.device, state.transfer_buf);

    // sampler
    const sampler_desc = std.mem.zeroInit(SamplerDesc, .{
        .min_filter = c.SDL_GPU_FILTER_NEAREST,
        .mag_filter = c.SDL_GPU_FILTER_NEAREST,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
    });

    // material
    try state.gpu_state.createMaterial(
        .sprite,
        pipeline_desc,
        .bricks,
        sampler_desc,
        @sizeOf(f32) * 32,
    );

    state.camera = try allocator.create(Camera);
    defer allocator.destroy(state.camera);
    state.camera.* = .init(.{ 960, 600 });

    // main loop
    outer: while (true) {
        var event = std.mem.zeroes(c.SDL_Event);
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => break :outer,

                c.SDL_EVENT_WINDOW_RESIZED => {
                    state.camera.viewport = .{
                        @floatFromInt(event.window.data1),
                        @floatFromInt(event.window.data2),
                    };
                },

                else => {},
            }
        }

        try render(state);
    }
}

fn render(state: *State) !void {
    const cmdbuf = try gpu.acquireCommandBuffer(state.device);
    var opt_swapchain: ?*c.SDL_GPUTexture = null;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmdbuf, state.window, &opt_swapchain,
null, null)) {
        log.err("Failed to acquire swapchain texture: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    }

    if (opt_swapchain) |swapchain| {
        const transfer_data: [*]Sprite =
            @ptrCast(@alignCast(c.SDL_MapGPUTransferBuffer(
                state.device,
                state.transfer_buf,
                true,
            )));
        defer c.SDL_UnmapGPUTransferBuffer(state.device, state.transfer_buf);

        transfer_data[0] = std.mem.zeroInit(Sprite, .{
            .pos = .{ -0.5, -0.5, 0 },
            .color = .{ 0, 1, 0, 1 },
            .size = .{ 1, 1 },
        });

        const copypass = try gpu.beginCopyPass(cmdbuf);
        c.SDL_UploadToGPUBuffer(
            copypass,
            &.{
                .transfer_buffer = state.transfer_buf,
                .offset = 0,
            },
            &.{
                .buffer = state.storage_buf,
                .offset = 0,
                .size = @sizeOf(Sprite) * 1,
            },
            true,
        );

        c.SDL_EndGPUCopyPass(copypass);

        const color_target_info = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
            .texture = swapchain,
            .clear_color = .{ 0, 0, 0, 1 },
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
        });

        const renderpass = c.SDL_BeginGPURenderPass(cmdbuf, &color_target_info, 1, null);
        if (renderpass == null) {
            log.err("Failed to begin render pass: {s}", .{c.SDL_GetError()});
            return error.GPUDevice;
        }

        const triangle = try state.gpu_state.getMaterial(.sprite);
        c.SDL_BindGPUGraphicsPipeline(renderpass, triangle.pipeline);
        c.SDL_BindGPUVertexStorageBuffers(
            renderpass,
            0,
            &[_]*c.SDL_GPUBuffer{state.storage_buf},
            1,
        );

        c.SDL_BindGPUFragmentSamplers(
            renderpass,
            0,
            &.{
                .texture = triangle.texture,
                .sampler = triangle.sampler,
            },
            1,
        );

        const u_view = state.camera.viewMatrix();
        triangle.writeMat4(mat4.flatten(u_view), 0);
        const u_proj = state.camera.projMatrix();
        triangle.writeMat4(mat4.flatten(u_proj), 1);

        const u_buf = triangle.uniform_buf;
        const stride = @sizeOf(f32) * 16;
        c.SDL_PushGPUVertexUniformData(
            cmdbuf,
            0,
            @ptrCast(u_buf.ptr),
            stride * 2,
        );

        c.SDL_DrawGPUPrimitives(renderpass, 6, 1, 0, 0);
        c.SDL_EndGPURenderPass(renderpass);
    }

    try gpu.submitCommandBuffer(cmdbuf);
}
