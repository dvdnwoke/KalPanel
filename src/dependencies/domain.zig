const std = @import("std");
const Interface = @import("interface.zig");
const Feature = @import("../features.zig").Feature;

fn checkDomainDeps() bool {
    // TODO: real check, e.g. nginx or bind present
    // For now, always return true in tests via mock or assume available
    return true;
}

fn installDomainDeps() !void {
    // TODO: install nginx, certbot, etc.
    std.log.info("Installing domain dependencies (nginx, etc.)", .{});
}

pub const dependency = Interface.Dependency{
    .name = "domain",
    .feature = .domain,
    .packages = &.{ "nginx", "certbot" },
    .check = checkDomainDeps,
    .install = installDomainDeps,
};
