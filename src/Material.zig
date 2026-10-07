const std = @import("std");

const sdl3 = @import("sdl3");
const c = sdl3.c;

const Self = @This();

pipeline: *c.SDL_GPUGraphicsPipeline,
texture: ?*c.SDL_GPUTexture,
sampler: ?*c.SDL_GPUSampler,
uniform_buf: []u8,

pub fn writeUniforms(self: *Self, uniforms: anytype) void {
    const bytes = std.mem.asBytes(&uniforms);
    std.debug.assert(bytes.len <= self.uniform_buf.len);
    @memcpy(self.uniform_buf[0..bytes.len], bytes);
}
