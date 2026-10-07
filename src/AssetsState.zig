const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.assets);
const Allocator = std.mem.Allocator;

const sdl3 = @import("sdl3");

const c = @import("root.zig").c;

const max_file_len = 500 * 1024;

pub const ShaderIndex = enum(u8) {
    sprite_vert,
    solid_color_frag,
};

pub const TextureIndex = enum {
    blue_rect,
    green_rect,
    purple_rect,
    red_rect,
    yellow_rect,
};

pub const MaterialIndex = enum {
    blue_rect,
};

const AssetsPack = struct {
    file: std.fs.File,

    pub fn open(path: []const u8) !AssetsPack {
        return .{
            .file = try std.fs.cwd().openFile(path, .{}),
        };
    }

    pub fn close(self: *AssetsPack) void {
        self.file.close();
    }

    pub fn read(
        self: *AssetsPack,
        gpa: Allocator,
        offset: u64,
        len: usize,
    ) ![]u8 {
        const buf = try gpa.alloc(u8, len);
        errdefer gpa.free(buf);

        var total: usize = 0;
        while (total < buf.len) {
            const n = try self.file.pread(buf[total..], offset + total);
            total += n;
        }

        return buf;
    }
};

const ShaderSlot = union(enum) {
    empty,
    ready: ShaderInfo,
};

const TextureSlot = union(enum) {
    empty,
    ready: TextureInfo,
};

const MaterialSlot = union(enum) {
    empty,
    ready: MaterialInfo,
};

const Self = @This();

arena: std.heap.ArenaAllocator,
assets_pack: AssetsPack,
shaders: std.EnumArray(ShaderIndex, ShaderSlot),
textures: std.EnumArray(TextureIndex, TextureSlot),
materials: std.EnumArray(MaterialIndex, MaterialSlot),

pub fn init(gpa: Allocator) !Self {
    const assets_path = try getAssetsPath(gpa);
    defer gpa.free(assets_path);

    const assets_pack_path = try std.fs.path.join(
        gpa,
        &.{ assets_path, "assets.pak" },
    );
    defer gpa.free(assets_pack_path);

    var self: Self = .{
        .arena = .init(gpa),
        .assets_pack = try AssetsPack.open(assets_pack_path),
        .shaders = std.EnumArray(ShaderIndex, ShaderSlot).initFill(.empty),
        .textures = std.EnumArray(TextureIndex, TextureSlot).initFill(.empty),
        .materials = std.EnumArray(MaterialIndex, MaterialSlot).initFill(.empty),
    };

    errdefer self.assets_pack.close();
    errdefer self.arena.deinit();

    try self.parseAssetsManifest(assets_path);

    return self;
}

pub fn deinit(self: *Self) void {
    self.assets_pack.close();
    self.arena.deinit();
}

pub fn readShaderCode(
    self: *Self,
    idx: ShaderIndex,
    format: c_uint,
) ![:0]u8 {
    const shaderinfo = self.getShaderInfo(idx);

    var offset: usize = 0;
    var len: usize = 0;
    var comp_len: usize = 0;
    if (format == sdl3.c.SDL_GPU_SHADERFORMAT_SPIRV) {
        offset = shaderinfo.spv_offset;
        len = shaderinfo.spv_len;
        comp_len = shaderinfo.spv_comp_len;
    } else if (format == sdl3.c.SDL_GPU_SHADERFORMAT_DXIL) {
        offset = shaderinfo.dxil_offset;
        len = shaderinfo.dxil_len;
        comp_len = shaderinfo.dxil_comp_len;
    } else {
        unreachable;
    }

    const gpa = self.arena.allocator();
    const compressed = try self.assets_pack.read(gpa, offset, comp_len);
    defer gpa.free(compressed);

    const buf = try gpa.allocSentinel(u8, len, 0);
    errdefer gpa.free(buf);

    const result = c.LZ4_decompress_safe(
        @ptrCast(compressed.ptr),
        buf.ptr,
        @intCast(comp_len),
        @intCast(len),
    );

    if (result < 0) {
        log.err("Failed to decompress shader code", .{});
        return error.LZ4Decompression;
    }

    return buf;
}

const ShaderJson = struct {
    samplers: c_uint,
    storage_textures: c_uint,
    storage_buffers: c_uint,
    uniform_buffers: c_uint,
};

pub fn readShaderJson(
    self: *Self,
    idx: ShaderIndex,
) !ShaderJson {
    const shaderinfo = self.getShaderInfo(idx);

    const offset = shaderinfo.json_offset;
    const len = shaderinfo.json_len;
    const comp_len = shaderinfo.json_comp_len;

    const gpa = self.arena.allocator();
    const compressed = try self.assets_pack.read(gpa, offset, comp_len);
    defer gpa.free(compressed);

    const buf = try gpa.allocSentinel(u8, len, 0);
    defer gpa.free(buf);

    const result = c.LZ4_decompress_safe(
        @ptrCast(compressed.ptr),
        buf.ptr,
        @intCast(comp_len),
        @intCast(len),
    );

    if (result < 0) {
        log.err("Failed to decompress shader json", .{});
        return error.LZ4Decompression;
    }

    return try std.json.parseFromSliceLeaky(
        ShaderJson,
        gpa,
        buf,
        .{ .ignore_unknown_fields = true },
    );
}

pub fn readTexture(
    self: *Self,
    idx: TextureIndex,
    width: *c_int,
    height: *c_int,
    channels: *c_int,
) ![*c]u8 {
    const textureinfo = self.getTextureInfo(idx);

    const file = try std.fs.openFileAbsolute(textureinfo.path, .{});
    defer file.close();

    const gpa = self.arena.allocator();
    const in_buf = try gpa.alloc(u8, 1024);
    defer gpa.free(in_buf);

    var reader = file.reader(in_buf);
    const out_buf = try reader.interface.allocRemaining(gpa, .limited(max_file_len));
    defer gpa.free(out_buf);

    return c.stbi_load_from_memory(
        out_buf.ptr,
        @intCast(out_buf.len),
        width,
        height,
        channels,
        0,
    );
}

const MaterialInfo = struct {
    json: MaterialJson,
};

pub fn getMaterialInfo(self: *Self, idx: MaterialIndex) *MaterialInfo {
    const slot = self.materials.getPtr(idx);
    return switch (slot.*) {
        .ready => |*materialinfo| materialinfo,
        .empty => {
            slot.* = .{ .ready = std.mem.zeroes(MaterialInfo) };
            return &slot.ready;
        },
    };
}

pub fn getShaderIndex(fname: []const u8) !ShaderIndex {
    const stem = std.fs.path.stem(fname);
    if (std.mem.eql(u8, stem, "sprite.vert")) {
        return .sprite_vert;
    } else if (std.mem.eql(u8, stem, "solid_color.frag")) {
        return .solid_color_frag;
    } else {
        log.err("Unexpected shader name {s}", .{fname});
        return error.ShaderName;
    }
}

pub fn getTextureIndex(fname: []const u8) !TextureIndex {
    const stem = std.fs.path.stem(fname);
    if (std.mem.eql(u8, stem, "blue_rectangle")) {
        return .blue_rect;
    } else if (std.mem.eql(u8, stem, "green_rectangle")) {
        return .green_rect;
    } else if (std.mem.eql(u8, stem, "purple_rectangle")) {
        return .purple_rect;
    } else if (std.mem.eql(u8, stem, "red_rectangle")) {
        return .red_rect;
    } else if (std.mem.eql(u8, stem, "yellow_rectangle")) {
        return .yellow_rect;
    } else {
        log.err("Unexpected texture name {s}", .{fname});
        return error.TextureName;
    }
}

fn getAssetsPath(gpa: Allocator) ![]const u8 {
    const bin_path = try std.fs.selfExeDirPathAlloc(gpa);
    defer gpa.free(bin_path);

    if (!std.mem.endsWith(u8, bin_path, "bin")) {
        log.err("Binary is not at the expected location: {s}", .{bin_path});
        return error.BinaryLocation;
    }

    const grandparent_path = std.fs.path.dirname(bin_path) orelse {
        log.err("Binary is not at the expected location: {s}", .{bin_path});
        return error.BinaryLocation;
    };

    return std.fs.path.join(gpa, &.{ grandparent_path, "assets" }) catch |err| {
        log.err("Failed to join paths", .{});
        return err;
    };
}

const ManifestEntryJson = struct {
    name: []const u8,
    offset: ?usize = null,
    len: ?usize = null,
    comp_len: ?usize = null,
};

fn parseAssetsManifest(self: *Self, assets_path: []const u8) !void {
    const gpa = self.arena.allocator();

    const manifest_path = try std.fs.path.join(gpa, &.{ assets_path, "manifest.json" });
    defer gpa.free(manifest_path);
    var manifest = try std.fs.openFileAbsolute(manifest_path, .{});
    defer manifest.close();

    const manifest_buf = try gpa.alloc(u8, 1024);
    defer gpa.free(manifest_buf);
    var reader = manifest.reader(manifest_buf);

    const json_buf = try reader.interface.allocRemaining(gpa, .limited(max_file_len));
    defer gpa.free(json_buf);

    const parsed = try std.json.parseFromSliceLeaky(
        []ManifestEntryJson,
        gpa,
        json_buf,
        .{},
    );

    for (parsed) |entry| {
        const name = entry.name;
        const offset = entry.offset;
        const len = entry.len;
        const comp_len = entry.comp_len;

        const asset_type = try getAssetType(name);
        switch (asset_type) {
            .shader_json,
            .shader_spv,
            .shader_dxil,
            => {
                const idx = try getShaderIndex(name);
                var shaderinfo = self.getShaderInfo(idx);

                switch (asset_type) {
                    .shader_json => {
                        shaderinfo.json_offset = offset.?;
                        shaderinfo.json_len = len.?;
                        shaderinfo.json_comp_len = comp_len.?;
                    },
                    .shader_spv => {
                        shaderinfo.spv_offset = offset.?;
                        shaderinfo.spv_len = len.?;
                        shaderinfo.spv_comp_len = comp_len.?;
                    },
                    .shader_dxil => {
                        shaderinfo.dxil_offset = offset.?;
                        shaderinfo.dxil_len = len.?;
                        shaderinfo.dxil_comp_len = comp_len.?;
                    },
                    else => unreachable,
                }
            },

            .texture => {
                const idx = try getTextureIndex(name);
                var textureinfo = self.getTextureInfo(idx);

                const path = try std.fs.path.join(gpa, &.{ assets_path, name });
                errdefer gpa.free(path);

                textureinfo.path = path;
            },

            .material => {
                const idx = try getMaterialIndex(name);
                var materialinfo = self.getMaterialInfo(idx);

                const json = try self.parseMaterialJson(offset.?, len.?, comp_len.?);
                materialinfo.json = json;
            },
        }
    }
}

const AssetType = enum {
    shader_json,
    shader_spv,
    shader_dxil,
    texture,
    material,
};

fn getAssetType(fname: []const u8) !AssetType {
    const ext = std.fs.path.extension(fname);
    if (std.mem.eql(u8, ext, ".json")) {
        return .shader_json;
    } else if (std.mem.eql(u8, ext, ".spv")) {
        return .shader_spv;
    } else if (std.mem.eql(u8, ext, ".dxil")) {
        return .shader_dxil;
    } else if (std.mem.eql(u8, ext, ".png")) {
        return .texture;
    } else if (std.mem.eql(u8, ext, ".mat")) {
        return .material;
    } else {
        log.err("Unexpected asset type {s}", .{fname});
        return error.AssetType;
    }
}

const ShaderInfo = struct {
    json_offset: usize,
    json_len: usize,
    json_comp_len: usize,
    spv_offset: usize,
    spv_len: usize,
    spv_comp_len: usize,
    dxil_offset: usize,
    dxil_len: usize,
    dxil_comp_len: usize,
};

fn getShaderInfo(self: *Self, idx: ShaderIndex) *ShaderInfo {
    const slot = self.shaders.getPtr(idx);
    return switch (slot.*) {
        .ready => |*shaderinfo| shaderinfo,
        .empty => {
            slot.* = .{ .ready = std.mem.zeroes(ShaderInfo) };
            return &slot.ready;
        },
    };
}

const TextureInfo = struct {
    path: []const u8,
};

fn getTextureInfo(self: *Self, idx: TextureIndex) *TextureInfo {
    const slot = self.textures.getPtr(idx);
    return switch (slot.*) {
        .ready => |*textureinfo| textureinfo,
        .empty => {
            slot.* = .{ .ready = std.mem.zeroes(TextureInfo) };
            return &slot.ready;
        },
    };
}

const MaterialJson = struct {
    vertex_shader: []const u8,
    fragment_shader: []const u8,
    texture: ?[]const u8 = null,
    sampler: ?enum {
        nearest,
    } = null,
    blend: ?enum {
        alpha,
    } = null,
};

fn parseMaterialJson(
    self: *Self,
    offset: usize,
    len: usize,
    comp_len: usize,
) !MaterialJson {
    const gpa = self.arena.allocator();
    const compressed = try self.assets_pack.read(gpa, offset, comp_len);
    defer gpa.free(compressed);

    const buf = try gpa.allocSentinel(u8, len, 0);
    errdefer gpa.free(buf);

    const result = c.LZ4_decompress_safe(
        @ptrCast(compressed.ptr),
        buf.ptr,
        @intCast(comp_len),
        @intCast(len),
    );

    if (result < 0 or result != len) {
        log.err("Failed to decompress shader json", .{});
        return error.LZ4Decompression;
    }

    return try std.json.parseFromSliceLeaky(
        MaterialJson,
        gpa,
        buf,
        .{},
    );
}

fn getMaterialIndex(fname: []const u8) !MaterialIndex {
    const stem = std.fs.path.stem(fname);
    if (std.mem.eql(u8, stem, "blue_rect")) {
        return .blue_rect;
    } else {
        log.err("Unexpected material name {s}", .{fname});
        return error.MaterialName;
    }
}
