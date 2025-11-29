const mat4 = @import("mat4.zig");
const quat = @import("quat.zig");

pub const Projection = union(enum) {
    orthographic: struct { scale: f32 },
    perspective: struct { radians: f32 },
};

pos: [3]f32 = @splat(0),
orientation: [4]f32 = quat.identity(),
proj: Projection = .{ .orthographic = .{ .scale = 1 } },

viewport: [2]f32,
aspect_ratio: f32,

near: f32 = 0.1,
far: f32 = 100,

pub fn init(viewport: [2]f32) @This() {
    const width, const height = .{ viewport[0], viewport[1] };
    return .{
        .viewport = viewport,
        .aspect_ratio = if (height == 0) 1 else width / height,
    };
}

pub fn viewMatrix(self: @This()) [4][4]f32 {
    const pos = self.pos;
    const conjugate = quat.conjugate(self.orientation);
    return mat4.mul(
        quat.toMat4(conjugate),
        mat4.translate(
            mat4.identity(),
            .{ -pos[0], -pos[1], -pos[2] },
        ),
    );
}

pub fn projMatrix(self: *@This()) [4][4]f32 {
    const width, const height = .{ self.viewport[0], self.viewport[1] };
    self.aspect_ratio = if (height == 0) 1 else width / height;

    return switch (self.proj) {
        .orthographic => |ortho| mat4.orthoAspect(
            ortho.scale,
            self.aspect_ratio,
            self.near,
            self.far,
        ),
        .perspective => |perspective| mat4.perspective(
            perspective.radians,
            self.aspect_ratio,
            self.near,
            self.far,
        ),
    };
}
