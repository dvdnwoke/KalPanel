const std = @import("std");
const Interface = @import("interface.zig");
const Feature = @import("../features.zig").Feature;

fn checkEmailDeps() bool {
    // TODO: check for postfix or exim
    return true;
}

fn installEmailDeps() !void {
    std.log.info("Installing email dependencies (postfix/exim)", .{});
}

pub const dependency = Interface.Dependency{
    .name = "email",
    .feature = .email,
    .packages = &.{ "postfix" },
    .check = checkEmailDeps,
    .install = installEmailDeps,
};
