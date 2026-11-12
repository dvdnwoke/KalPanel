const std = @import("std");
const Interface = @import("interface.zig");
const Feature = @import("../features.zig").Feature;

fn checkDomainDeps() bool {
    // At least one of the core tools must be present
    return Interface.commandExists("nginx") or Interface.commandExists("apache2");
}

fn installDomainDeps() Interface.InstallError!void {
    std.log.info("Domain deps missing. Install nginx (or apache2) and certbot on the host.", .{});
    // Real install would call package manager here; for now we report clearly
    return error.DependenciesNotInstalled;
}

pub const dependency = Interface.Dependency{
    .name = "domain",
    .feature = .domain,
    .packages = &.{ "nginx", "certbot" },
    .check = checkDomainDeps,
    .install = installDomainDeps,
};
