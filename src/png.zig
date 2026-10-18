//! Writes 8-bit RGBA PNGs, for the `none` host's snapshots.
const std = @import("std");
const flate = std.compress.flate;

/// Encodes `width` by `height` pixels of straight (not premultiplied) RGBA,
/// rows `stride` bytes apart, as a PNG.
pub fn encode(gpa: std.mem.Allocator, rgba: []const u8, width: u32, height: u32, stride: u32) ![]u8 {
    // the image data: each row behind a "no filter" byte, then compressed
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(gpa);
    try raw.ensureTotalCapacity(gpa, @as(usize, height) * (width * 4 + 1));
    for (0..height) |y| {
        raw.appendAssumeCapacity(0);
        raw.appendSliceAssumeCapacity(rgba[y * stride ..][0 .. width * 4]);
    }

    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 1 << 16);
    defer compressed.deinit();
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const compress = try gpa.create(flate.Compress);
    defer gpa.destroy(compress);
    compress.* = try .init(&compressed.writer, window, .zlib, .level_4);
    try compress.writer.writeAll(raw.items);
    try compress.finish();

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll("\x89PNG\r\n\x1a\n");
    var header: [13]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], width, .big);
    std.mem.writeInt(u32, header[4..8], height, .big);
    header[8..13].* = .{ 8, 6, 0, 0, 0 }; // 8 bits, RGBA, deflate, no filter, no interlace
    try chunk(w, "IHDR", &header);
    try chunk(w, "IDAT", compressed.written());
    try chunk(w, "IEND", "");
    return out.toOwnedSlice();
}

fn chunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc: std.hash.Crc32 = .init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

test "a PNG starts with its signature and header, and ends with IEND" {
    const pixels = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 128 };
    const encoded = try encode(std.testing.allocator, &pixels, 2, 1, 8);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualSlices(u8, "\x89PNG\r\n\x1a\n", encoded[0..8]);
    try std.testing.expectEqualSlices(u8, "IHDR", encoded[12..16]);
    try std.testing.expectEqualSlices(u8, "IEND", encoded[encoded.len - 8 ..][0..4]);
}
