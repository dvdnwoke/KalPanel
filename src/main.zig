const std = @import("std");
const manager = @import("dependencies/manager.zig");
const FeatureSet = @import("features.zig").FeatureSet;

pub fn main() !void {
    // Replace this with the features actually enabled across users.
    const used = FeatureSet{ .domain = true, .php = true };

    var gaps: [8]manager.Gap = undefined;
    const n = manager.collectMissing(used, &gaps);
    if (n == 0) {
        std.debug.print("Dependencies ready.\n", .{});
        return;
    }

    std.debug.print("Missing dependencies:\n", .{});
    for (gaps[0..n]) |gap| {
        std.debug.print("  {s} requires {s}\n", .{ gap.name, gap.command });
    }
    return error.DependenciesNotInstalled;
}
