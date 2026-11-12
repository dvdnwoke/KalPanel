const std = @import("std");
const Feature = @import("features.zig").Feature;

pub const InstallError = error{
    DependenciesNotInstalled,
};

/// One feature's required host binaries.
/// `check` passes only when every command is on PATH. Alternatives do not count.
pub const Dependency = struct {
    name: []const u8,
    feature: Feature,
    commands: []const []const u8,

    pub fn check(self: Dependency) bool {
        for (self.commands) |cmd| {
            if (!commandExists(cmd)) return false;
        }
        return true;
    }

    /// Writes the commands that are not on PATH. Returns how many were written.
    pub fn missing(self: Dependency, out: [][]const u8) usize {
        var count: usize = 0;
        for (self.commands) |cmd| {
            if (commandExists(cmd)) continue;
            if (count < out.len) {
                out[count] = cmd;
                count += 1;
            }
        }
        return count;
    }
};

/// Returns true if `cmd` is an executable on PATH.
pub fn commandExists(cmd: []const u8) bool {
    const allocator = std.heap.page_allocator;
    var threaded: std.Io.Threaded = .init(allocator, .{});
    defer threaded.deinit();

    const result = std.process.run(allocator, threaded.io(), .{
        .argv = &.{ "which", cmd },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    return result.term.success();
}
