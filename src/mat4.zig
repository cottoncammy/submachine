const std = @import("std");

const vec3 = @import("vec3.zig");

const mat4 = @This();

pub fn identity() [4][4]f32 {
    var result = std.mem.zeroes([4][4]f32);
    result[0][0] = 1;
    result[1][1] = 1;
    result[2][2] = 1;
    result[3][3] = 1;
    return result;
}

pub fn flatten(self: [4][4]f32) [16]f32 {
    var result = std.mem.zeroes([16]f32);
    inline for (0..4) |i| {
        inline for (0..4) |j| {
            result[j * 4 + i] = self[i][j];
        }
    }
    return result;
}

pub fn mul(a: [4][4]f32, b: [4][4]f32) [4][4]f32 {
    var result = std.mem.zeroes([4][4]f32);
    inline for (0..4) |i| {
        inline for (0..4) |j| {
            inline for (0..4) |k| {
                result[i][j] += a[i][k] * b[k][j];
            }
        }
    }
    return result;
}

pub fn scale(self: [4][4]f32, v: [3]f32) [4][4]f32 {
    var scale_mat = mat4.identity();
    scale_mat[0][0] = v[0];
    scale_mat[1][1] = v[1];
    scale_mat[2][2] = v[2];
    return mat4.mul(scale_mat, self);
}

pub fn translate(self: [4][4]f32, v: [3]f32) [4][4]f32 {
    var translate_mat = mat4.identity();
    translate_mat[0][3] = v[0];
    translate_mat[1][3] = v[1];
    translate_mat[2][3] = v[2];
    return mat4.mul(translate_mat, self);
}

pub fn rotate(self: [4][4]f32, v: [3]f32, radians: f32) [4][4]f32 {
    const unit_v = vec3.normalize(v);
    const x = unit_v[0];
    const y = unit_v[1];
    const z = unit_v[2];

    const sin_theta = @sin(radians);
    const cos_theta = @cos(radians);

    var rotate_mat = mat4.identity();

    rotate_mat[0][0] = x * x * (1 - cos_theta) + cos_theta;
    rotate_mat[0][1] = x * y * (1 - cos_theta) - z * sin_theta;
    rotate_mat[0][2] = x * z * (1 - cos_theta) + y * sin_theta;

    rotate_mat[1][0] = x * y * (1 - cos_theta) + z * sin_theta;
    rotate_mat[1][1] = y * y * (1 - cos_theta) + cos_theta;
    rotate_mat[1][2] = y * z * (1 - cos_theta) - x * sin_theta;

    rotate_mat[2][0] = x * z * (1 - cos_theta) - y * sin_theta;
    rotate_mat[2][1] = y * z * (1 - cos_theta) + x * sin_theta;
    rotate_mat[2][2] = z * z * (1 - cos_theta) + cos_theta;

    return mat4.mul(rotate_mat, self);
}

pub fn ortho(
    left: f32,
    right: f32,
    bottom: f32,
    top: f32,
    near: f32,
    far: f32,
) [4][4]f32 {
    var result = mat4.identity();
    result[0][0] = 2 / (right - left);
    result[0][3] = -(right + left) / (right - left);
    result[1][1] = 2 / (top - bottom);
    result[1][3] = -(top + bottom) / (top - bottom);
    result[2][2] = 1 / (far - near);
    result[2][3] = -near / (far - near);
    return result;
}

pub fn orthoAspect(
    scale_factor: f32,
    aspect_ratio: f32,
    near: f32,
    far: f32,
) [4][4]f32 {
    const right, const top = blk: {
        if (aspect_ratio > 1) {
            break :blk .{ scale_factor * aspect_ratio, scale_factor };
        } else {
            break :blk .{ scale_factor, scale_factor / aspect_ratio };
        }
    };

    return mat4.ortho(-right, right, top, -top, near, far);
}

pub fn perspective(
    radians: f32,
    aspect_ratio: f32,
    near: f32,
    far: f32,
) [4][4]f32 {
    const tan_half_theta = @tan(radians / 2);
    var result = std.mem.zeroes([4][4]f32);
    result[0][0] = 1 / (aspect_ratio * tan_half_theta);
    result[1][1] = 1 / tan_half_theta;
    result[2][2] = far / (near - far);
    result[2][3] = -(far * near) / (far - near);
    result[3][2] = -1;
    return result;
}
