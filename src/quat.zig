const mat4 = @import("mat4.zig");

const quat = @This();

pub fn identity() [4]f32 {
    return .{ 1, 0, 0, 0 };
}

pub fn conjugate(self: [4]f32) [4]f32 {
    return .{ self[0], -self[1], -self[2], -self[3] };
}

pub fn toMat4(self: [4]f32) [4][4]f32 {
    var result = mat4.identity();
    const xx = self[1] * self[1];
    const yy = self[2] * self[2];
    const zz = self[3] * self[3];
    const xz = self[1] * self[3];
    const xy = self[1] * self[2];
    const yz = self[2] * self[3];
    const wx = self[0] * self[1];
    const wy = self[0] * self[2];
    const wz = self[0] * self[3];

    result[0][0] = 1 - 2 * (yy + zz);
    result[0][1] = 2 * (xy + wz);
    result[0][2] = 2 * (xz - wy);

    result[1][0] = 2 * (xy - wz);
    result[1][1] = 1 - 2 * (xx + zz);
    result[1][2] = 2 * (yz + wx);

    result[2][0] = 2 * (xz + wy);
    result[2][1] = 2 * (yz - wx);
    result[2][2] = 1 - 2 * (xx + yy);
    return result;
}
