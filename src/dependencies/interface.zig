const std = @import("std");
const Feature = @import("../features.zig").Feature;

pub const Dependency = struct {
    name: []const u8,
    feature: Feature,
    packages: []const []const u8,
    check: *const fn () bool,
    install: *const fn () !void,
};

/// Returns true if the command exists in PATH.
/// Safe for tests: returns false on any failure.
pub fn commandExists(cmd: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "command", "-v", cmd },
    }) catch return false;

    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return switch (result.term) {
        .Exited => |code| code == 0,
        else => false,
    };
}
