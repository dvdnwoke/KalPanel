const std = @import("std");
const manager = @import("dependencies/manager.zig");
const FeatureSet = @import("features.zig").FeatureSet;

pub fn main() !void {
    std.debug.print("KalPanel — Light, Easy, and Fast Hosting Control Panel\n", .{});
    std.debug.print("Dependencies module loaded.\n", .{});

    // Example: only domain and php are used by at least one user
    const used = FeatureSet{ .domain = true, .php = true };
    try manager.ensureDependencies(used);
    std.debug.print("Dependency check/install complete for enabled features.\n", .{});
}
