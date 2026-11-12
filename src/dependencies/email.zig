const std = @import("std");
const Interface = @import("interface.zig");
const Feature = @import("../features.zig").Feature;

fn checkEmailDeps() bool {
    return Interface.commandExists("postfix") or Interface.commandExists("exim4");
}

fn installEmailDeps() Interface.InstallError!void {
    std.log.info("Email deps missing. Install postfix or exim on the host.", .{});
    return error.DependenciesNotInstalled;
}

pub const dependency = Interface.Dependency{
    .name = "email",
    .feature = .email,
    .packages = &.{ "postfix" },
    .check = checkEmailDeps,
    .install = installEmailDeps,
};
