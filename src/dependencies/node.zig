const std = @import("std");
const Interface = @import("interface.zig");
const Feature = @import("../features.zig").Feature;

fn checkNodeDeps() bool {
    return true;
}

fn installNodeDeps() !void {
    std.log.info("Installing Node.js runtime dependencies", .{});
}

pub const dependency = Interface.Dependency{
    .name = "node",
    .feature = .node,
    .packages = &.{ "nodejs", "npm" },
    .check = checkNodeDeps,
    .install = installNodeDeps,
};
