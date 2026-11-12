const std = @import("std");

/// `root` empty means the real filesystem. Tests pass an absolute prefix.
pub const Layout = struct {
    root: []const u8,

    pub fn resolve(self: Layout, buf: []u8, rel: []const u8) ![]u8 {
        if (self.root.len == 0) return std.fmt.bufPrint(buf, "/{s}", .{rel});
        return std.fmt.bufPrint(buf, "{s}/{s}", .{ self.root, rel });
    }

    pub fn system(self: Layout) bool {
        return self.root.len == 0;
    }
};

pub fn writeFile(io: std.Io, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        try std.Io.Dir.cwd().createDirPath(io, parent);
    }
    var file = try std.Io.Dir.createFileAbsolute(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, data);
}

pub fn readFile(io: std.Io, path: []const u8, buf: []u8) ![]u8 {
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

pub fn removeFile(io: std.Io, path: []const u8) void {
    std.Io.Dir.deleteFileAbsolute(io, path) catch {};
}

pub fn add(buf: []u8, len: *usize, text: []const u8) !void {
    if (len.* + text.len > buf.len) return error.ConfigTooLarge;
    @memcpy(buf[len.*..][0..text.len], text);
    len.* += text.len;
}
