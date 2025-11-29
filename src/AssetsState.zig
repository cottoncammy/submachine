const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.assets);

const Allocator = std.mem.Allocator;

const c = @import("root.zig").c;

const max_file_len = 500 * 1024;

const max_shaders_len = 2;
const max_textures_len = 1;

const ManifestEntryJson = struct {
    name: []const u8,
    offset: usize,
    len: usize,
    comp_len: usize,
};

const AssetType = enum {
    shader_json,
    shader_spv,
    texture_png,
};

pub const ShaderInfo = struct {
    json_offset: usize,
    json_len: usize,
    json_comp_len: usize,
    spv_offset: usize,
    spv_len: usize,
    spv_comp_len: usize,
};

pub const TextureInfo = struct {
    offset: usize,
    len: usize,
};

pub const ShaderIndex = enum(u8) {
    triangle_vert = (0 << 1) | 0,
    color_frag = (1 << 1) | 1,
};

pub const TextureIndex = enum {
    bricks,
};

file_map: []align(std.heap.page_size_min) const u8,
shaders_lut: []?*ShaderInfo,
textures_lut: []?*TextureInfo,

const Self = @This();

pub fn init(gpa: Allocator) !Self {
    var state = std.mem.zeroes(Self);
    state.shaders_lut = try gpa.alloc(?*ShaderInfo, max_shaders_len);
    errdefer gpa.free(state.shaders_lut);
    @memset(state.shaders_lut, null);

    state.textures_lut = try gpa.alloc(?*TextureInfo, max_textures_len);
    @memset(state.textures_lut, null);
    return state;
}

pub fn deinit(self: *Self, gpa: Allocator) void {
    self.munmapAssetsPack();
    for (self.textures_lut) |opt_textureinfo| {
        if (opt_textureinfo) |textureinfo| {
            gpa.destroy(textureinfo);
        }
    }
    gpa.free(self.textures_lut);

    for (self.shaders_lut) |opt_shaderinfo| {
        if (opt_shaderinfo) |shaderinfo| {
            gpa.destroy(shaderinfo);
        }
    }
    gpa.free(self.shaders_lut);
}

fn munmapAssetsPack(self: *Self) void {
    std.posix.munmap(self.file_map);
}

pub fn parseAssetsManifest(self: *Self, gpa: Allocator) !void {
    const assets_path = try getAssetsPath(gpa);
    defer gpa.free(assets_path);
    const assets_pack_path = try std.fs.path.join(gpa, &.{ assets_path, "assets.pak" });
    defer gpa.free(assets_pack_path);

    try self.mmapAssetsPack(assets_pack_path);

    const manifest_path = try std.fs.path.join(gpa, &.{ assets_path, "manifest.json" });
    defer gpa.free(manifest_path);
    var manifest = try std.fs.openFileAbsolute(manifest_path, .{});
    defer manifest.close();

    const manifest_buf = try gpa.alloc(u8, 1024);
    defer gpa.free(manifest_buf);
    var reader = manifest.reader(manifest_buf);

    const json_buf = try reader.interface.allocRemaining(gpa, .limited(max_file_len));
    defer gpa.free(json_buf);

    const parsed = try std.json.parseFromSlice([]ManifestEntryJson, gpa, json_buf, .{});
    defer parsed.deinit();

    for (parsed.value) |entry| {
        const name = entry.name;
        const offset = entry.offset;
        const len = entry.len;
        const comp_len = entry.comp_len;

        const asset_type = try getAssetType(name);
        switch (asset_type) {
            .shader_json, .shader_spv => {
                const shaderidx = try getShaderIndex(name);
                const shaderinfo = self.getShaderInfo(gpa, shaderidx) catch |err| {
                    log.err(
                        "Failed to get shader info for {s}: {s}",
                        .{ name, @errorName(err) },
                    );
                    return err;
                };

                if (asset_type == .shader_json) {
                    shaderinfo.json_offset = offset;
                    shaderinfo.json_len = len;
                    shaderinfo.json_comp_len = comp_len;
                } else {
                    shaderinfo.spv_offset = offset;
                    shaderinfo.spv_len = len;
                    shaderinfo.spv_comp_len = comp_len;
                }
            },

            .texture_png => {
                const textureidx = try getTextureIndex(name);
                const textureinfo = self.getTextureInfo(gpa, textureidx) catch |err| {
                    log.err(
                        "Failed to get texture info for {s}: {s}",
                        .{ name, @errorName(err) },
                    );
                    return err;
                };
                textureinfo.offset = offset;
                textureinfo.len = len;
            },
        }
    }
}

fn getAssetsPath(gpa: Allocator) ![]const u8 {
    const buf = try gpa.alloc(u8, std.posix.PATH_MAX);
    defer gpa.free(buf);
    @memset(buf, 0);

    const bin_path = try std.posix.readlink("/proc/self/exe", buf);
    const parent_path = std.fs.path.dirname(bin_path) orelse {
        log.err("Binary is not at the expected location: {s}", .{bin_path});
        return error.BinaryLocation;
    };

    if (!std.mem.endsWith(u8, parent_path, "bin")) {
        log.err("Binary is not at the expected location: {s}", .{bin_path});
        return error.BinaryLocation;
    }

    const grandparent_path = std.fs.path.dirname(parent_path) orelse {
        log.err("Binary is not at the expected location: {s}", .{bin_path});
        return error.BinaryLocation;
    };

    return std.fs.path.join(gpa, &.{ grandparent_path, "assets" }) catch |err| {
        log.err("Failed to join paths", .{});
        return err;
    };
}

fn mmapAssetsPack(self: *Self, path: []const u8) !void {
    const fd = try std.posix.open(path, .{}, 0o444);
    defer std.posix.close(fd);
    const stat = try std.posix.fstat(fd);
    self.file_map = try std.posix.mmap(
        null,
        @intCast(stat.size),
        std.posix.PROT.READ,
        .{ .TYPE = .PRIVATE },
        fd,
        0,
    );
}

fn getAssetType(fname: []const u8) !AssetType {
    const extension = std.fs.path.extension(fname);
    if (std.mem.eql(u8, extension, ".json")) {
        return .shader_json;
    } else if (std.mem.eql(u8, extension, ".spv")) {
        return .shader_spv;
    } else if (std.mem.eql(u8, extension, ".png")) {
        return .texture_png;
    } else {
        log.err("Unexpected asset type {s}", .{fname});
        return error.AssetType;
    }
}

fn getShaderInfo(self: *Self, gpa: Allocator, shaderidx: u8) !*ShaderInfo {
    if (self.shaders_lut.len <= shaderidx or self.shaders_lut[shaderidx] == null) {
        const shaderinfo = try gpa.create(ShaderInfo);
        shaderinfo.* = std.mem.zeroes(ShaderInfo);
        self.shaders_lut[shaderidx] = shaderinfo;
    }
    return self.shaders_lut[shaderidx] orelse unreachable;
}

fn getShaderIndex(fname: []const u8) !u8 {
    const stem = std.fs.path.stem(fname);
    if (std.mem.eql(u8, stem, "triangle.vert")) {
        return @intFromEnum(ShaderIndex.triangle_vert) >> 1;
    } else if (std.mem.eql(u8, stem, "color.frag")) {
        return @intFromEnum(ShaderIndex.color_frag) >> 1;
    } else {
        log.err("Unexpected shader name {s}", .{fname});
        return error.ShaderName;
    }
}

fn getTextureIndex(fname: []const u8) !TextureIndex {
    const stem = std.fs.path.stem(fname);
    if (std.mem.eql(u8, stem, "bricks")) {
        return .bricks;
    } else {
        log.err("Unexpected texture name {s}", .{fname});
        return error.ShaderName;
    }
}

fn getTextureInfo(self: *Self, gpa: Allocator, textureidx: TextureIndex) !*TextureInfo {
    const idx = @intFromEnum(textureidx);
    if (self.textures_lut.len <= idx or self.textures_lut[idx] == null) {
        const textureinfo = try gpa.create(TextureInfo);
        textureinfo.* = std.mem.zeroes(TextureInfo);
        self.textures_lut[idx] = textureinfo;
    }
    return self.textures_lut[idx] orelse unreachable;
}

pub fn readTexture(
    self: *Self,
    gpa: std.mem.Allocator,
    textureidx: TextureIndex,
    width: *c_int,
    height: *c_int,
    channels: *c_int,
) ![*c]u8 {
    const idx = @intFromEnum(textureidx);
    std.debug.assert(self.textures_lut.len > idx);
    const textureinfo = self.textures_lut[idx].?;
    const buf = try gpa.alloc(u8, textureinfo.len);
    defer gpa.free(buf);

    @memcpy(
        buf,
        self.file_map[textureinfo.offset .. textureinfo.offset + textureinfo.len],
    );

    return c.stbi_load_from_memory(
        buf.ptr,
        @intCast(buf.len),
        width,
        height,
        channels,
        0,
    );
}
