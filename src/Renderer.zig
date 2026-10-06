const std = @import("std");
const log = std.log.scoped(.render);

const Allocator = std.mem.Allocator;

const c = @import("root.zig").c;
const gpu = @import("gpu.zig");
const mat4 = @import("mat4.zig");
const Camera = @import("Camera.zig");
const GpuState = @import("GpuState.zig");
const Material = @import("Material.zig");
const RenderState = @import("RenderState.zig");

pub const SpriteInstance = extern struct {
    pos: [3]f32,
    rotation: f32,
    color: [4]f32,
    size: [2]f32,
    _pad1: [2]f32,
};

pub const SpriteUniforms = extern struct {
    view: [16]f32,
    proj: [16]f32,
};

const Self = @This();

window: *c.SDL_Window,
device: *c.SDL_GPUDevice,
storage_buf: *c.SDL_GPUBuffer,
transfer_buf: *c.SDL_GPUTransferBuffer,
max_sprites: u32,

pub fn init(window: *c.SDL_Window, device: *c.SDL_GPUDevice) !Self {
    var self: Self = .{
        .window = window,
        .device = device,
        .storage_buf = undefined,
        .transfer_buf = undefined,
        .max_sprites = 10,
    };

    // storage buffer
    const storage_buf_info = c.SDL_GPUBufferCreateInfo{
        .usage = c.SDL_GPU_BUFFERUSAGE_GRAPHICS_STORAGE_READ,
        .size = @sizeOf(SpriteInstance) * self.max_sprites,
    };

    self.storage_buf = try gpu.createBuffer(self.device, &storage_buf_info);
    errdefer c.SDL_ReleaseGPUBuffer(self.device, self.storage_buf);

    const transfer_buf_info = c.SDL_GPUTransferBufferCreateInfo{
        .usage = c.SDL_GPU_TRANSFERBUFFERUSAGE_UPLOAD,
        .size = @sizeOf(SpriteInstance) * self.max_sprites,
    };

    self.transfer_buf = try gpu.createTransferBuffer(self.device, &transfer_buf_info);
    errdefer c.SDL_ReleaseGPUTransferBuffer(self.device, self.transfer_buf);

    return self;
}

pub fn deinit(self: *Self) void {
    c.SDL_ReleaseGPUTransferBuffer(self.device, self.transfer_buf);
    c.SDL_ReleaseGPUBuffer(self.device, self.storage_buf);
}

pub fn render(
    self: *Self,
    gpa: Allocator,
    render_state: *const RenderState,
    gpu_state: *GpuState,
    camera: *Camera,
) !void {
    const cmdbuf = try gpu.acquireCommandBuffer(self.device);

    var opt_swapchain: ?*c.SDL_GPUTexture = null;
    if (!c.SDL_WaitAndAcquireGPUSwapchainTexture(cmdbuf, self.window, &opt_swapchain, null, null)) {
        log.err("Failed to acquire swapchain texture: {s}", .{c.SDL_GetError()});
        return error.GPUDevice;
    }

    if (opt_swapchain) |swapchain| {
        const addr = c.SDL_MapGPUTransferBuffer(
            self.device,
            self.transfer_buf,
            true,
        ) orelse {
            log.err("Failed to map GPU transfer buffer: {s}", .{c.SDL_GetError()});
            return error.GPUBuffer;
        };

        const transfer_data: [*]SpriteInstance = @ptrCast(@alignCast(addr));
        defer c.SDL_UnmapGPUTransferBuffer(self.device, self.transfer_buf);

        const batches = try render_state.buildBatches(gpa);
        defer gpa.free(batches);

        const cmds = render_state.draw_queue.items;
        if (cmds.len > self.max_sprites) {
            return error.TooManySprites;
        }

        for (cmds, 0..) |cmd, i| {
            switch (cmd) {
                .sprite => |sprite| {
                    transfer_data[i] = std.mem.zeroInit(SpriteInstance, .{
                        .pos = sprite.pos,
                        .rotation = sprite.rotation,
                        .color = sprite.color,
                        .size = sprite.size,
                    });
                },
            }
        }

        const copypass = try gpu.beginCopyPass(cmdbuf);

        c.SDL_UploadToGPUBuffer(
            copypass,
            &.{
                .transfer_buffer = self.transfer_buf,
                .offset = 0,
            },
            &.{
                .buffer = self.storage_buf,
                .offset = 0,
                .size = @sizeOf(SpriteInstance) * @as(u32, @intCast(cmds.len)),
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

        c.SDL_BindGPUVertexStorageBuffers(
            renderpass,
            0,
            &[_]*c.SDL_GPUBuffer{self.storage_buf},
            1,
        );

        const u_view = camera.viewMatrix();
        const u_proj = camera.projMatrix();

        const uniforms: SpriteUniforms = .{
            .view = mat4.flatten(u_view),
            .proj = mat4.flatten(u_proj),
        };

        for (batches) |batch| {
            var material = try gpu_state.getMaterial(batch.material);
            self.bindMaterial(renderpass, &material);

            material.writeUniforms(uniforms);
            self.pushUniforms(cmdbuf, &material);

            switch (batch.draw_type) {
                .sprite => c.SDL_DrawGPUPrimitives(
                    renderpass,
                    @intCast(6 * batch.len),
                    1,
                    @intCast(6 * batch.offset),
                    0,
                ),
            }
        }

        c.SDL_EndGPURenderPass(renderpass);
    }

    try gpu.submitCommandBuffer(cmdbuf);
}

fn bindMaterial(
    _: *const Self,
    renderpass: ?*c.SDL_GPURenderPass,
    material: *const Material,
) void {
    c.SDL_BindGPUGraphicsPipeline(renderpass, material.pipeline);
    c.SDL_BindGPUFragmentSamplers(
        renderpass,
        0,
        &.{
            .texture = material.texture,
            .sampler = material.sampler,
        },
        1,
    );
}

fn pushUniforms(_: *const Self, cmdbuf: ?*c.SDL_GPUCommandBuffer, material: *const Material) void {
    const buf = material.uniform_buf;

    c.SDL_PushGPUVertexUniformData(
        cmdbuf,
        0,
        @ptrCast(buf.ptr),
        @intCast(buf.len),
    );
}
