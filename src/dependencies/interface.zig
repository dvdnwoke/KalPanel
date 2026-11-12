const std = @import("std");
const Feature = @import("../features.zig").Feature;

pub const InstallError = error{
    DependenciesNotInstalled,
};

pub const Dependency = struct {
    name: []const u8,
    feature: Feature,
    packages: []const []const u8,
    check: *const fn () bool,
    install: *const fn () InstallError!void,
};

/// Returns true if `cmd` is an executable on PATH.
/// Safe for tests: returns false on any failure.
pub fn commandExists(cmd: []const u8) bool {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    // `command` is a shell builtin. `which` is a real executable.
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const result = std.process.run(allocator, threaded.io(), .{
        .argv = &.{ "which", cmd },
    }) catch return false;

    return result.term.success();
}
