const std = @import("std");
const builtin = @import("builtin");
const log = std.log.scoped(.assets);

const Allocator = std.mem.Allocator;

const c = @import("root.zig").c;

pub const max_shaders_len = 2;
pub const max_textures_len = 1;

const max_file_len = 500 * 1024;

pub const ShaderInfo = struct {
    json_offset: usize,
    json_len: usize,
    json_comp_len: usize,
    spv_offset: usize,
    spv_len: usize,
    spv_comp_len: usize,
};

pub const AssetInfo = struct {
    offset: usize,
    len: usize,
};

pub const ShaderIndex = enum(u8) {
    sprite_vert = (0 << 1) | 0,
    solid_color_frag = (1 << 1) | 1,
};

pub const TextureIndex = enum {
    bricks,
};

pub const ShaderJson = struct {
    samplers: c_uint,
    storage_textures: c_uint,
    storage_buffers: c_uint,
    uniform_buffers: c_uint,
};

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

file_map: []align(std.heap.page_size_min) const u8,

shaders_lut: []?*ShaderInfo,
textures_lut: []?*AssetInfo,

const Self = @This();

pub fn init(gpa: Allocator) !Self {
    var self: Self = .{
        .file_map = &.{},
        .shaders_lut = &.{},
        .textures_lut = &.{},
    };

    self.shaders_lut = try gpa.alloc(?*ShaderInfo, max_shaders_len);
    errdefer gpa.free(self.shaders_lut);
    @memset(self.shaders_lut, null);

    self.textures_lut = try gpa.alloc(?*AssetInfo, max_textures_len);
    @memset(self.textures_lut, null);
    return self;
}

pub fn deinit(self: *Self, gpa: Allocator) void {
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

pub fn munmapAssetsPack(self: *Self) void {
    std.posix.munmap(self.file_map);
}

pub fn parseAssetsManifest(self: *Self, gpa: Allocator) !void {
    const assets_path = try getAssetsPath(gpa);
    defer gpa.free(assets_path);
    const assets_pack_path = try std.fs.path.join(gpa, &.{ assets_path, "assets.pak" });
    defer gpa.free(assets_pack_path);

    try self.mmapAssetsPack(assets_pack_path);
    errdefer self.munmapAssetsPack();

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
            .shader_json,
            .shader_spv,
            => {
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

pub fn readShaderCode(
    self: *Self,
    gpa: Allocator,
    shaderidx: ShaderIndex,
    format: c_uint,
) ![:0]u8 {
    const idx = @intFromEnum(shaderidx) >> 1;
    std.debug.assert(self.shaders_lut.len > idx);
    const shaderinfo = self.shaders_lut[idx].?;

    var offset: usize = 0;
    var len: usize = 0;
    var comp_len: usize = 0;
    if (format == c.SDL_GPU_SHADERFORMAT_SPIRV) {
        offset = shaderinfo.spv_offset;
        len = shaderinfo.spv_len;
        comp_len = shaderinfo.spv_comp_len;
    } else {
        unreachable;
    }

    const code = try gpa.allocSentinel(u8, len, 0);
    errdefer gpa.free(code);

    const result = c.LZ4_decompress_safe(
        @ptrCast(self.file_map[offset .. offset + comp_len]),
        code.ptr,
        @intCast(comp_len),
        @intCast(len),
    );
    if (result == 0) {
        log.err("Failed to decompress shader code", .{});
        return error.LZ4Decompress;
    }
    return code;
}

pub fn readShaderJson(
    self: *Self,
    gpa: Allocator,
    shaderidx: ShaderIndex,
) !std.json.Parsed(ShaderJson) {
    const idx = @intFromEnum(shaderidx) >> 1;
    std.debug.assert(self.shaders_lut.len > idx);
    const shaderinfo = self.shaders_lut[idx].?;

    const offset = shaderinfo.json_offset;
    const len = shaderinfo.json_len;
    const comp_len = shaderinfo.json_comp_len;

    const buf = try gpa.allocSentinel(u8, len, 0);
    defer gpa.free(buf);

    const result = c.LZ4_decompress_safe(
        @ptrCast(self.file_map[offset .. offset + comp_len]),
        buf.ptr,
        @intCast(comp_len),
        @intCast(len),
    );
    if (result == 0) {
        log.err("Failed to decompress shader json", .{});
        return error.LZ4Decompress;
    }

    return try std.json.parseFromSlice(
        ShaderJson,
        gpa,
        buf,
        .{ .ignore_unknown_fields = true },
    );
}

pub fn readTexture(
    self: *Self,
    gpa: Allocator,
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
    if (std.mem.eql(u8, stem, "sprite.vert")) {
        return @intFromEnum(ShaderIndex.sprite_vert) >> 1;
    } else if (std.mem.eql(u8, stem, "solid_color.frag")) {
        return @intFromEnum(ShaderIndex.solid_color_frag) >> 1;
    } else {
        log.err("Unexpected shader name {s}", .{fname});
        return error.ShaderName;
    }
}

fn getTextureInfo(self: *Self, gpa: Allocator, textureidx: TextureIndex) !*AssetInfo {
    const idx = @intFromEnum(textureidx);
    if (self.textures_lut.len <= idx or self.textures_lut[idx] == null) {
        const textureinfo = try gpa.create(AssetInfo);
        textureinfo.* = std.mem.zeroes(AssetInfo);
        self.textures_lut[idx] = textureinfo;
    }
    return self.textures_lut[idx] orelse unreachable;
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
