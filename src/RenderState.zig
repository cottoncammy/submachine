const std = @import("std");
const Allocator = std.mem.Allocator;

const AssetsState = @import("AssetsState.zig");
const MaterialIndex = AssetsState.MaterialIndex;

pub const Sprite = struct {
    material: MaterialIndex,
    pos: [3]f32,
    rotation: f32,
    color: [4]f32,
    size: [2]f32,
};

const DrawType = enum {
    sprite,
};

pub const DrawCommand = union(DrawType) {
    sprite: Sprite,
};

const RenderBatch = struct {
    draw_type: DrawType,
    material: MaterialIndex,
    offset: usize,
    len: usize,
};

const BatchKey = struct {
    draw_type: DrawType,
    material: MaterialIndex,
};

const Self = @This();

draw_queue: std.ArrayListUnmanaged(DrawCommand),

pub fn init() !Self {
    return .{ .draw_queue = .empty };
}

pub fn deinit(self: *Self, gpa: Allocator) void {
    self.draw_queue.deinit(gpa);
}

pub fn clearDrawQueue(self: *Self) void {
    self.draw_queue.clearRetainingCapacity();
}

pub fn pushDraw(self: *Self, gpa: Allocator, cmd: DrawCommand) !void {
    try self.draw_queue.append(gpa, cmd);
}

pub fn buildBatches(self: Self, gpa: Allocator) ![]RenderBatch {
    const cmds = self.draw_queue.items;

    var batches: std.ArrayListUnmanaged(RenderBatch) = .empty;
    errdefer batches.deinit(gpa);

    var i: usize = 0;
    while (i < cmds.len) {
        const key = getBatchKey(cmds[i]);
        var j: usize = i + 1;

        while (j < cmds.len and std.meta.eql(key, getBatchKey(cmds[j]))) {
            j += 1;
        }

        try batches.append(gpa, .{
            .draw_type = key.draw_type,
            .material = key.material,
            .offset = i,
            .len = j - i,
        });

        i = j;
    }

    return try batches.toOwnedSlice(gpa);
}

fn getBatchKey(cmd: DrawCommand) BatchKey {
    return switch (cmd) {
        .sprite => |sprite| .{
            .draw_type = .sprite,
            .material = sprite.material,
        },
    };
}
