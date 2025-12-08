const std = @import("std");
const Allocator = std.mem.Allocator;

const GpuState = @import("GpuState.zig");
const MaterialIndex = GpuState.MaterialIndex;

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

pub const DrawCommandContext = struct {
    pub fn lessThan(ctx: DrawCommandContext, lhs: DrawCommand, rhs: DrawCommand) bool {
        _ = ctx;
        if (!std.mem.eql(u8, @tagName(lhs), @tagName(rhs))) {
            return @intFromEnum(lhs) < @intFromEnum(rhs);
        }

        switch (lhs) {
            .sprite => |l| {
                const r = rhs.sprite;
                return @intFromEnum(l.material) < @intFromEnum(r.material);
            },
        }
    }
};

const RenderBatch = struct {
    material: MaterialIndex,
    base: usize,
    count: usize,
};

const Self = @This();

draw_queue: *std.ArrayListUnmanaged(DrawCommand),

pub fn init(gpa: Allocator) !Self {
    var self: Self = .{ .draw_queue = undefined };
    self.draw_queue = try gpa.create(std.ArrayListUnmanaged(DrawCommand));
    self.draw_queue.* = .empty;
    return self;
}

pub fn deinit(self: *Self, gpa: Allocator) void {
    self.draw_queue.deinit(gpa);
    gpa.destroy(self.draw_queue);
}

pub fn clearDrawQueue(self: *Self) void {
    self.draw_queue.clearRetainingCapacity();
}

pub fn pushDraw(self: *Self, gpa: Allocator, cmd: DrawCommand) !void {
    try self.draw_queue.append(gpa, cmd);
}

pub fn buildBatches(self: Self, gpa: Allocator) ![]RenderBatch {
    const cmds = self.draw_queue.items;
    const ctx: DrawCommandContext = .{};
    std.mem.sort(
        DrawCommand,
        cmds,
        ctx,
        DrawCommandContext.lessThan,
    );

    var batches: std.ArrayListUnmanaged(RenderBatch) = .empty;
    errdefer batches.deinit(gpa);

    var i: usize = 0;
    while (i < cmds.len) {
        const cmd = cmds[i];
        const material = cmd.sprite.material;
        var j: usize = i + 1;
        while (j < cmds.len) {
            const next = cmds[j];
            if (@intFromEnum(material) ==
                @intFromEnum(next.sprite.material))
            {
                j += 1;
            } else {
                break;
            }
        }

        try batches.append(gpa, .{
            .material = material,
            .base = i,
            .count = j - i,
        });

        i = j;
    }

    return try batches.toOwnedSlice(gpa);
}
