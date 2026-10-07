const std = @import("std");
const Allocator = std.mem.Allocator;

const dvui = @import("dvui");

const RenderState = @import("RenderState.zig");

const SceneIndex = enum {
    main_menu,
};

const FrameContext = struct {
    gpa: Allocator,
    render_state: *RenderState,
    dvui_window: *dvui.Window,
};

pub const Scene = union(SceneIndex) {
    main_menu: MainMenu,

    pub fn init(idx: SceneIndex) Scene {
        return switch (idx) {
            .main_menu => .{ .main_menu = MainMenu.init() },
        };
    }

    pub fn deinit(self: *Scene) void {
        switch (self.*) {
            inline else => |*scene| scene.deinit(),
        }
    }

    pub fn frame(self: *Scene, ctx: FrameContext) !void {
        switch (self.*) {
            inline else => |*scene| try scene.frame(ctx),
        }
    }
};

const MainMenu = struct {
    pub fn init() MainMenu {
        return .{};
    }

    pub fn deinit(self: *MainMenu) void {
        _ = self;
    }

    pub fn frame(self: *MainMenu, ctx: FrameContext) !void {
        _ = self;
        _ = ctx;

        var float = dvui.floatingWindow(@src(), .{}, .{ .max_size_content = .{ .w = 400, .h = 400 } });
        defer float.deinit();
        float.dragAreaSet(dvui.windowHeader("Floating Window", "", null));
    }
};
