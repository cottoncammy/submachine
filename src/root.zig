const std = @import("std");

const App = @import("App.zig");

pub const c = @cImport({
    @cInclude("SDL3/SDL.h");
    @cInclude("lz4.h");
    @cInclude("stb_image.h");
});

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var app: App = try .init(allocator);
    defer app.deinit(allocator);
    try app.run(allocator);
}
