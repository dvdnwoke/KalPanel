const std = @import("std");
const Interface = @import("interface.zig");
const Feature = @import("../features.zig").Feature;

fn checkNodeDeps() bool {
    return Interface.commandExists("node") or Interface.commandExists("nodejs");
}

fn installNodeDeps() !void {
    std.log.info("Node.js runtime missing. Install nodejs and npm on the host.", .{});
    return error.DependenciesNotInstalled;
}

pub const dependency = Interface.Dependency{
    .name = "node",
    .feature = .node,
    .packages = &.{ "nodejs", "npm" },
    .check = checkNodeDeps,
    .install = installNodeDeps,
};
