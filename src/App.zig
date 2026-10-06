const std = @import("std");
const log = std.log.scoped(.app);

const Allocator = std.mem.Allocator;

const c = @import("root.zig").c;
const AssetsState = @import("AssetsState.zig");
const RenderState = @import("RenderState.zig");
const GpuState = @import("GpuState.zig");
const PipelineDesc = GpuState.PipelineDesc;
const SamplerDesc = GpuState.SamplerDesc;
const Renderer = @import("Renderer.zig");
const SpriteUniforms = Renderer.SpriteUniforms;
const Camera = @import("Camera.zig");

window: *c.SDL_Window,
device: *c.SDL_GPUDevice,
assets: AssetsState,
gpu: GpuState,
renderer: Renderer,
render_state: RenderState,
camera: Camera,

const Self = @This();

pub fn init(gpa: Allocator) !Self {
    var self: Self = .{
        .window = undefined,
        .device = undefined,
        .assets = undefined,
        .gpu = undefined,
        .renderer = undefined,
        .render_state = undefined,
        .camera = undefined,
    };

    if (!c.SDL_SetAppMetadata("submachine", "0.1.0", "xyz.cottoncammy")) {
        log.err("Failed to set app metadata: {s}", .{c.SDL_GetError()});
        return error.SDLInit;
    }
    if (!c.SDL_Init(c.SDL_INIT_VIDEO)) {
        log.err("Failed to initialize SDL: {s}", .{c.SDL_GetError()});
        return error.SDLInit;
    }
    errdefer c.SDL_Quit();

    // window
    _ = c.SDL_WINDOWPOS_CENTERED;
    self.window = c.SDL_CreateWindow("submachine", 960, 600, 0) orelse {
        log.err("Failed to create window: {s}", .{c.SDL_GetError()});
        return error.SDLInit;
    };
    errdefer c.SDL_DestroyWindow(self.window);

    // device
    const device_flags = c.SDL_GPU_SHADERFORMAT_SPIRV | c.SDL_GPU_SHADERFORMAT_DXIL;
    self.device = c.SDL_CreateGPUDevice(device_flags, true, null) orelse {
        log.err("Failed to create GPU device: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    };
    errdefer c.SDL_DestroyGPUDevice(self.device);

    if (!c.SDL_ClaimWindowForGPUDevice(self.device, self.window)) {
        log.err("Failed to claim window for GPU device: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    }
    errdefer c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);

    // assets state
    self.assets = try .init(gpa);
    errdefer self.assets.deinit();

    // gpu state
    self.gpu = try .init(gpa, &self.assets, self.device);
    errdefer self.gpu.deinit();

    // renderer
    self.renderer = try .init(self.window, self.device);
    errdefer self.renderer.deinit();

    // render state
    self.render_state = try .init();
    errdefer self.render_state.deinit(gpa);

    // camera
    self.camera = .init(.{ 960, 600 });

    self.camera.proj = .{ .orthographic = .{
        .bottom = 0,
        .top = 100,
        .left = 0,
        .right = 100,
    } };

    // pipeline
    var pipeline_desc = std.mem.zeroInit(PipelineDesc, .{
        .vert_shader = .sprite_vert,
        .frag_shader = .solid_color_frag,
    });

    pipeline_desc.target_info = std.mem.zeroInit(c.SDL_GPUGraphicsPipelineTargetInfo, .{
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
    });

    // sampler
    const sampler_desc = std.mem.zeroInit(SamplerDesc, .{
        .min_filter = c.SDL_GPU_FILTER_NEAREST,
        .mag_filter = c.SDL_GPU_FILTER_NEAREST,
        .mipmap_mode = c.SDL_GPU_SAMPLERMIPMAPMODE_NEAREST,
        .address_mode_u = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_v = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
        .address_mode_w = c.SDL_GPU_SAMPLERADDRESSMODE_CLAMP_TO_EDGE,
    });

    // materials
    try self.gpu.createMaterial(SpriteUniforms, .{
        .idx = .blue_rect,
        .pipeline = pipeline_desc,
        .texture = .blue_rect,
        .sampler = sampler_desc,
    });

    return self;
}

pub fn deinit(self: *Self, gpa: Allocator) void {
    self.render_state.deinit(gpa);
    self.gpu.deinit();
    self.assets.deinit();

    c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
    c.SDL_DestroyGPUDevice(self.device);
    c.SDL_DestroyWindow(self.window);
    c.SDL_Quit();
}

pub fn run(self: *Self, gpa: Allocator) !void {
    outer: while (true) {
        var event = std.mem.zeroes(c.SDL_Event);
        while (c.SDL_PollEvent(&event)) {
            switch (event.type) {
                c.SDL_EVENT_QUIT => break :outer,

                c.SDL_EVENT_WINDOW_RESIZED => {
                    self.camera.viewport = .{
                        @floatFromInt(event.window.data1),
                        @floatFromInt(event.window.data2),
                    };
                },

                else => {},
            }
        }

        // draws
        self.render_state.clearDrawQueue();

        try self.render_state.pushDraw(gpa, .{
            .sprite = .{
                .material = .blue_rect,
                .pos = .{ 0, 0, 0 },
                .rotation = 0,
                .color = .{ 1, 1, 1, 1 },
                .size = .{ 12, 10 },
            },
        });

        try self.renderer.render(gpa, self.render_state, &self.gpu, &self.camera);
    }
}
