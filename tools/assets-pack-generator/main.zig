const std = @import("std");
const log = std.log.scoped(.assets_pack_generator);

const Allocator = std.mem.Allocator;

const c = @cImport({
    @cInclude("lz4.h");
});

const max_file_len = 2 * 1024 * 1024;

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa.deinit() == .ok);
    const allocator = gpa.allocator();

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();
    _ = args.skip();

    const assets_path = args.next().?;
    var dir = try std.fs.openDirAbsolute(assets_path, .{ .iterate = true });
    defer dir.close();

    // assets.pak
    var assets = try dir.createFile("assets.pak", .{});
    defer assets.close();
    const assets_buf = try allocator.alloc(u8, 2048);
    defer allocator.free(assets_buf);
    var assets_writer = assets.writer(assets_buf);

    // manifest.json
    var manifest = try dir.createFile("manifest.json", .{});
    defer manifest.close();
    const manifest_buf = try allocator.alloc(u8, 1024);
    defer allocator.free(manifest_buf);
    var manifest_writer = manifest.writer(manifest_buf);

    var stringify: std.json.Stringify = .{ .writer = &manifest_writer.interface };
    try stringify.beginArray();
    var offset: usize = 0;
    while (args.next()) |arg| {
        try writeManifestEntry(
            allocator,
            arg,
            &stringify,
            &assets_writer,
            &offset,
        );
    }

    try stringify.endArray();
    try assets_writer.interface.flush();
    try manifest_writer.interface.flush();
}

fn writeManifestEntry(
    gpa: Allocator,
    path: []const u8,
    stringify: *std.json.Stringify,
    writer: *std.fs.File.Writer,
    offset: *usize,
) !void {
    try stringify.beginObject();
    const name = std.fs.path.basename(path);
    try stringify.objectField("name");
    try stringify.write(name);
    try stringify.objectField("offset");
    try stringify.write(offset);

    var file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    const file_buf = try gpa.alloc(u8, 1024);
    defer gpa.free(file_buf);
    var reader = file.reader(file_buf);

    const in_buf = try reader.interface.allocRemaining(gpa, .limited(max_file_len));
    defer gpa.free(in_buf);
    const in_buf_nul = try gpa.dupeZ(u8, in_buf);
    defer gpa.free(in_buf_nul);

    const out_buf = try gpa.allocSentinel(u8, max_file_len, 0);
    defer gpa.free(out_buf);

    const len = in_buf_nul.len;
    var comp_len: usize = 0;
    if (std.mem.endsWith(u8, name, ".png")) {
        offset.* += len;
        _ = try writer.interface.write(in_buf_nul);
    } else {
        comp_len = @intCast(c.LZ4_compress_default(
            in_buf_nul.ptr,
            out_buf.ptr,
            @intCast(in_buf_nul.len),
            @intCast(out_buf.len),
        ));
        if (comp_len == 0) {
            log.err("Failed to compress asset {s}", .{name});
            return error.LZ4Compression;
        }
        offset.* += comp_len;
        _ = try writer.interface.write(out_buf[0..comp_len]);
    }

    try stringify.objectField("len");
    try stringify.write(len);
    try stringify.objectField("comp_len");
    try stringify.write(comp_len);
    try stringify.endObject();
}
