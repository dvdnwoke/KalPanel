const std = @import("std");

/// Ubuntu is the only supported host for system accounts.
pub const Host = struct {
    pub fn home(self: Host, io: std.Io, name: []const u8, buf: []u8) ![]const u8 {
        _ = self;
        if (!try osIsUbuntu(io)) return error.UnsupportedSystem;
        if (try unixUserExists(io, name)) return error.SystemUserExists;

        const home_path = try std.fmt.bufPrint(buf, "/home/{s}", .{name});
        var args: [10][]const u8 = undefined;
        fillUseraddArgs(name, home_path, &args);

        const allocator = std.heap.page_allocator;
        const result = std.process.run(allocator, io, .{
            .argv = &args,
        }) catch |err| {
            std.debug.print("useradd failed to start: {s}\n", .{@errorName(err)});
            return error.AccountCreateFailed;
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        if (!result.term.success()) {
            if (result.stderr.len > 0) std.debug.print("{s}", .{result.stderr});
            if (result.stderr.len == 0 or result.stderr[result.stderr.len - 1] != '\n') std.debug.print("\n", .{});
            return error.AccountCreateFailed;
        }
        return home_path;
    }

    pub fn rollback(self: Host, io: std.Io, name: []const u8) void {
        _ = self;
        const allocator = std.heap.page_allocator;
        const result = std.process.run(allocator, io, .{
            .argv = &.{ "/usr/sbin/userdel", "-r", name },
        }) catch return;
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
    }
};

/// A normal account in the `users` group. `-N` skips a private group, so the
/// name `admin` does not collide with Ubuntu's existing `admin` group and
/// does not land in that sudo group.
pub fn fillUseraddArgs(name: []const u8, home_path: []const u8, out: *[10][]const u8) void {
    out.* = .{ "/usr/sbin/useradd", "-m", "-N", "-g", "users", "-d", home_path, "-s", "/bin/bash", name };
}

fn unixUserExists(io: std.Io, name: []const u8) !bool {
    const allocator = std.heap.page_allocator;
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "/usr/bin/id", "-u", name },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    return result.term.success();
}

pub fn idFromOsRelease(contents: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, contents, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "ID=")) continue;
        var value = line["ID=".len..];
        if (value.len >= 2 and value[0] == '"' and value[value.len - 1] == '"') {
            value = value[1 .. value.len - 1];
        }
        return value;
    }
    return null;
}

fn osIsUbuntu(io: std.Io) !bool {
    var file = std.Io.Dir.openFileAbsolute(io, "/etc/os-release", .{}) catch return false;
    defer file.close(io);
    var buf: [4096]u8 = undefined;
    const n = try file.readPositionalAll(io, &buf, 0);
    const id = idFromOsRelease(buf[0..n]) orelse return false;
    return std.mem.eql(u8, id, "ubuntu");
}
