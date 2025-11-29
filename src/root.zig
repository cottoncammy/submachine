const std = @import("std");
const log = std.log.scoped(.root);

const gpu = @import("gpu.zig");
const mat4 = @import("mat4.zig");
const Camera = @import("Camera.zig");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("lz4.h");
    @cInclude("stb_image.h");
});

pub const AssetsState = @import("AssetsState.zig");

pub const State = struct {
    window: *c.SDL_Window,
    device: *c.SDL_GPUDevice,
    assets_state: *AssetsState,
    fill_pipeline: *c.SDL_GPUGraphicsPipeline,
    vert_buf: *c.SDL_GPUBuffer,
    texture: *c.SDL_GPUTexture,
    sampler: *c.SDL_GPUSampler,
    camera: *Camera,
};

const Vertex = struct {
    position: [3]f32,
    color: [4]f32,
    texture: [2]f32,
};

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

    // shaders
    const vert_shader = try gpu.createShader(state, allocator, .triangle_vert);
    defer c.SDL_ReleaseGPUShader(state.device, vert_shader);

    const frag_shader = try gpu.createShader(state, allocator, .color_frag);
    defer c.SDL_ReleaseGPUShader(state.device, frag_shader);

    // pipeline
    const vert_input_state = std.mem.zeroInit(c.SDL_GPUVertexInputState, .{
        .num_vertex_buffers = 1,
        .vertex_buffer_descriptions = &[_]c.SDL_GPUVertexBufferDescription{
            .{
                .slot = 0,
                .input_rate = c.SDL_GPU_VERTEXINPUTRATE_VERTEX,
                .instance_step_rate = 0,
                .pitch = @sizeOf(Vertex),
            },
        },
        .num_vertex_attributes = 3,
        .vertex_attributes = &[_]c.SDL_GPUVertexAttribute{
            .{
                .buffer_slot = 0,
                .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT3,
                .location = 0,
                .offset = 0,
            },
            .{
                .buffer_slot = 0,
                .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT4,
                .location = 1,
                .offset = @sizeOf(f32) * 3,
            },
            .{
                .buffer_slot = 0,
                .format = c.SDL_GPU_VERTEXELEMENTFORMAT_FLOAT2,
                .location = 2,
                .offset = @sizeOf(f32) * 3 + @sizeOf(f32) * 4,
            },
        },
    });
    const target_info = std.mem.zeroInit(c.SDL_GPUGraphicsPipelineTargetInfo, .{
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

    state.fill_pipeline = try gpu.createPipeline(
        state,
        vert_shader,
        frag_shader,
        vert_input_state,
        target_info,
        c.SDL_GPU_FILLMODE_FILL,
    );
    defer c.SDL_ReleaseGPUGraphicsPipeline(state.device, state.fill_pipeline);

    // buffer
    state.vert_buf = try gpu.createBuffer(
        state,
        c.SDL_GPU_BUFFERUSAGE_VERTEX,
        @sizeOf(Vertex) * 3,
    );
    defer c.SDL_ReleaseGPUBuffer(state.device, state.vert_buf);

    // texture
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;

    var brick_texture = try state.assets_state.readTexture(
        allocator,
        .bricks,
        &width,
        &height,
        &channels,
    );
    defer c.stbi_image_free(brick_texture);

    state.texture = try gpu.createTexture(state, @intCast(width), @intCast(height));
    defer c.SDL_ReleaseGPUTexture(state.device, state.texture);

    state.sampler = try gpu.createSampler(state);
    defer c.SDL_ReleaseGPUSampler(state.device, state.sampler);

    // transfer buffers
    {
        const transfer_buf = try gpu.createTransferBuffer(
            state,
            c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            @sizeOf(Vertex) * 3,
        );
        defer c.SDL_ReleaseGPUTransferBuffer(state.device, transfer_buf);

        const transfer_data: [*]Vertex =
            @ptrCast(@alignCast(c.SDL_MapGPUTransferBuffer(
                state.device,
                transfer_buf,
                false,
            )));

        transfer_data[0] =
            .{
                .position = .{ -1, -1, 0 },
                .color = .{ 1, 0, 0, 1 },
                .texture = .{ 0, 0 },
            };
        transfer_data[1] =
            .{
                .position = .{ 1, -1, 0 },
                .color = .{ 0, 1, 0, 1 },
                .texture = .{ 1, 0 },
            };
        transfer_data[2] =
            .{
                .position = .{ 0, 1, 0 },
                .color = .{ 0, 0, 1, 1 },
                .texture = .{ 1, 1 },
            };
        c.SDL_UnmapGPUTransferBuffer(state.device, transfer_buf);

        const texture_transfer_buf = try gpu.createTransferBuffer(
            state,
            c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
            @intCast(width * height * channels),
        );
        defer c.SDL_ReleaseGPUTransferBuffer(state.device, texture_transfer_buf);

        const texture_transfer_data: [*]u8 =
            @ptrCast(c.SDL_MapGPUTransferBuffer(
                state.device,
                texture_transfer_buf,
                false,
            ));
        const len: usize = @intCast(width * height * channels);
        @memcpy(texture_transfer_data[0..len], brick_texture[0..len]);
        c.SDL_UnmapGPUTransferBuffer(state.device, texture_transfer_buf);

        const cmdbuf = c.SDL_AcquireGPUCommandBuffer(state.device);
        if (cmdbuf == null) {
            log.err("Failed to acquire command buffer: {s}", .{c.SDL_GetError()});
            return error.GPUDevice;
        }
        const copypass = c.SDL_BeginGPUCopyPass(cmdbuf);
        if (copypass == null) {
            return error.CopyPass;
        }

        c.SDL_UploadToGPUBuffer(
            copypass,
            &c.SDL_GPUTransferBufferLocation{
                .transfer_buffer = transfer_buf,
                .offset = 0,
            },
            &c.SDL_GPUBufferRegion{
                .buffer = state.vert_buf,
                .offset = 0,
                .size = @sizeOf(Vertex) * 3,
            },
            false,
        );

        c.SDL_UploadToGPUTexture(
            copypass,
            &c.SDL_GPUTextureTransferInfo{
                .transfer_buffer = texture_transfer_buf,
                .offset = 0,
            },
            &c.SDL_GPUTextureRegion{
                .texture = state.texture,
                .w = @intCast(width),
                .h = @intCast(height),
                .d = 1,
            },
            false,
        );

        c.SDL_EndGPUCopyPass(copypass);
        if (!c.SDL_SubmitGPUCommandBuffer(cmdbuf)) {
            log.err("Failed to submit command buffer: {s}", .{c.SDL_GetError()});
            return error.GPUDevice;
        }
    }

    state.camera = try allocator.create(Camera);
    defer allocator.destroy(state.camera);

    state.camera.* = .init(.{ 960, 600 });
    state.camera.pos = .{ 0, 0, 3 };

    // main loop
    outer: while (true) {
        var event: c.SDL_Event = undefined;
        while (c.SDL_PollEvent(&event)) {
            if (event.type == c.SDL_EVENT_QUIT) {
                break :outer;
            } else if (event.type == c.SDL_EVENT_WINDOW_RESIZED) {
                state.camera.viewport = .{
                    @floatFromInt(event.window.data1),
                    @floatFromInt(event.window.data2),
                };
            }
        }
        try iterate(state);
    }
}

fn iterate(state: *State) !void {
    const cmdbuf = c.SDL_AcquireGPUCommandBuffer(state.device);
    if (cmdbuf == null) {
        log.err("Failed to acquire command buffer: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    }

    var opt_swapchain: ?*c.SDL_GPUTexture = null;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmdbuf, state.window, &opt_swapchain, null, null)) {
        log.err("Failed to acquire swapchain texture: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    }

    if (opt_swapchain) |swapchain| {
        const color_target_info = std.mem.zeroInit(c.SDL_GPUColorTargetInfo, .{
            .texture = swapchain,
            .clear_color = .{ 0, 0, 0, 1 },
            .load_op = c.SDL_GPU_LOADOP_CLEAR,
            .store_op = c.SDL_GPU_STOREOP_STORE,
        });

        const renderpass = c.SDL_BeginGPURenderPass(cmdbuf, &color_target_info, 1, null);

        c.SDL_BindGPUGraphicsPipeline(renderpass, state.fill_pipeline);
        c.SDL_BindGPUVertexBuffers(
            renderpass,
            0,
            &.{ .buffer = state.vert_buf, .offset = 0 },
            1,
        );

        c.SDL_BindGPUFragmentSamplers(
            renderpass,
            0,
            &c.SDL_GPUTextureSamplerBinding{
                .texture = state.texture,
                .sampler = state.sampler,
            },
            1,
        );

        var u_buf = std.mem.zeroes([48]f32);
        const u_model = mat4.scale(mat4.identity(), .{ 0.5, 0.5, 0.5 });
        var flat_model = mat4.flatten(u_model);
        @memcpy(u_buf[0..16], flat_model[0..]);

        const u_view = state.camera.viewMatrix();
        var flat_view = mat4.flatten(u_view);
        @memcpy(u_buf[16..32], flat_view[0..]);

        const u_proj = state.camera.projMatrix();
        var flat_proj = mat4.flatten(u_proj);
        @memcpy(u_buf[32..48], flat_proj[0..]);

        c.SDL_PushGPUVertexUniformData(
            cmdbuf,
            0,
            u_buf[0..],
            @sizeOf(f32) * 48,
        );

        c.SDL_DrawGPUPrimitives(renderpass, 3, 1, 0, 0);
        c.SDL_EndGPURenderPass(renderpass);
    }

    if (!c.SDL_SubmitGPUCommandBuffer(cmdbuf)) {
        log.err("Failed to submit command buffer: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    }
}
