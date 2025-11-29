const std = @import("std");

const vec3 = @This();

pub fn magnitude(self: [3]f32) f32 {
    return @sqrt(self[0] * self[0] + self[1] * self[1] + self[2] * self[2]);
}

pub fn normalize(self: [3]f32) [3]f32 {
    const len = vec3.magnitude(self);
    if (len == 0) return std.mem.zeroes([3]f32);
    const inv = 1 / len;
    return .{ self[0] * inv, self[1] * inv, self[2] * inv };
}
