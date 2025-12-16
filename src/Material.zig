const std = @import("std");

const root = @import("root.zig");
const c = root.c;

const Self = @This();

pipeline: *c.SDL_GPUGraphicsPipeline,
texture: ?*c.SDL_GPUTexture,
sampler: ?*c.SDL_GPUSampler,
uniform_buf: []u8,

pub fn writeMat4(self: *Self, mat: [16]f32, offset: usize) void {
    const stride = @sizeOf(f32) * 16;
    const start = offset * stride;
    const src: []const u8 = @ptrCast(mat[0..]);
    @memcpy(self.uniform_buf[start .. start + stride], src.ptr);
}
