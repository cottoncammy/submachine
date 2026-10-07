const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.app);
const Allocator = std.mem.Allocator;

const dvui = @import("dvui");
const sdl3 = @import("sdl3");
const c = sdl3.c;

const AssetsState = @import("AssetsState.zig");
const RenderState = @import("RenderState.zig");
const GpuState = @import("GpuState.zig");
const PipelineDesc = GpuState.PipelineDesc;
const SamplerDesc = GpuState.SamplerDesc;
const Renderer = @import("Renderer.zig");
const SpriteUniforms = Renderer.SpriteUniforms;
const Camera = @import("Camera.zig");
const Scene = @import("scene.zig").Scene;
const gpu = @import("gpu.zig");

const Self = @This();

window: *c.SDL_Window,
device: *c.SDL_GPUDevice,
dvui_backend: *sdl3,
dvui_window: dvui.Window,
assets_state: AssetsState,
gpu_state: GpuState,
renderer: Renderer,
render_state: RenderState,
camera: Camera,
scene: Scene,

pub fn init(gpa: Allocator) !Self {
    var self: Self = .{
        .window = undefined,
        .device = undefined,
        .dvui_backend = undefined,
        .dvui_window = undefined,
        .assets_state = undefined,
        .gpu_state = undefined,
        .renderer = undefined,
        .render_state = undefined,
        .camera = undefined,
        .scene = undefined,
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
    const debug = builtin.mode == .Debug;
    self.device = c.SDL_CreateGPUDevice(device_flags, debug, null) orelse {
        log.err("Failed to create GPU device: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    };
    errdefer c.SDL_DestroyGPUDevice(self.device);

    if (!c.SDL_ClaimWindowForGPUDevice(self.device, self.window)) {
        log.err("Failed to claim window for GPU device: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    }
    errdefer c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);

    // dvui
    self.dvui_backend = try gpa.create(sdl3);
    errdefer gpa.destroy(self.dvui_backend);
    self.dvui_backend.* = sdl3.init(self.window, self.device, gpa);
    errdefer self.dvui_backend.deinit();

    self.dvui_window = try dvui.Window.init(
        @src(),
        gpa,
        self.dvui_backend.backend(),
        .{},
    );

    errdefer self.dvui_window.deinit();

    // assets state
    self.assets_state = try .init(gpa);
    errdefer self.assets_state.deinit();

    // gpu state
    self.gpu_state = try .init(gpa, self.window, self.device, &self.assets_state);
    errdefer self.gpu_state.deinit();

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

    // scene
    self.scene = Scene.init(.main_menu);

    // materials
    try self.gpu_state.createMaterial(SpriteUniforms, .blue_rect);

    return self;
}

pub fn deinit(self: *Self, gpa: Allocator) void {
    self.scene.deinit();
    self.render_state.deinit(gpa);
    self.renderer.deinit();
    self.gpu_state.deinit();
    self.assets_state.deinit();
    self.dvui_window.deinit();
    self.dvui_backend.deinit();
    gpa.destroy(self.dvui_backend);

    c.SDL_ReleaseWindowFromGPUDevice(self.device, self.window);
    c.SDL_DestroyGPUDevice(self.device);
    c.SDL_DestroyWindow(self.window);
    c.SDL_Quit();
}

pub fn run(self: *Self, gpa: Allocator) !void {
    outer: while (true) {
        const cmdbuf = try gpu.acquireCommandBuffer(self.device);

        var opt_swapchain: ?*c.SDL_GPUTexture = null;
        if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(
            cmdbuf,
            self.window,
            &opt_swapchain,
            null,
            null,
        )) {
            try gpu.submitCommandBuffer(cmdbuf);
            log.err("Failed to acquire swapchain texture: {s}", .{c.SDL_GetError()});
            return error.GPUDevice;
        }

        var quit = false;
        if (opt_swapchain) |swapchain| {
            self.dvui_backend.cmd = cmdbuf;
            self.dvui_backend.swapchain_texture = swapchain;

            try self.dvui_window.begin(std.time.nanoTimestamp());

            var event = std.mem.zeroes(c.SDL_Event);
            while (c.SDL_PollEvent(&event)) {
                switch (event.type) {
                    c.SDL_EVENT_QUIT => {
                        quit = true;
                        break;
                    },

                    c.SDL_EVENT_WINDOW_RESIZED => {
                        self.camera.viewport = .{
                            @floatFromInt(event.window.data1),
                            @floatFromInt(event.window.data2),
                        };
                    },

                    else => {},
                }

                _ = try self.dvui_backend.addEvent(&self.dvui_window, event);
            }

            if (!quit) {
                self.render_state.clearDrawQueue();

                try self.scene.frame(.{
                    .gpa = gpa,
                    .render_state = &self.render_state,
                    .dvui_window = &self.dvui_window,
                });

                try self.renderer.render(
                    gpa,
                    cmdbuf,
                    swapchain,
                    &self.render_state,
                    &self.gpu_state,
                    &self.camera,
                );
            }

            _ = try self.dvui_window.end(.{});
            try self.dvui_backend.renderPresent();
        }

        try gpu.submitCommandBuffer(cmdbuf);

        if (opt_swapchain != null and quit) break :outer;
    }
}
