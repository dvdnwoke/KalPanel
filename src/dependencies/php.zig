const std = @import("std");
const Interface = @import("interface.zig");
const Feature = @import("../features.zig").Feature;

fn checkPhpDeps() bool {
    return Interface.commandExists("php") or Interface.commandExists("php-fpm");
}

fn installPhpDeps() Interface.InstallError!void {
    std.log.info("PHP runtime missing. Install php and php-fpm on the host.", .{});
    return error.DependenciesNotInstalled;
}

pub const dependency = Interface.Dependency{
    .name = "php",
    .feature = .php,
    .packages = &.{ "php", "php-fpm" },
    .check = checkPhpDeps,
    .install = installPhpDeps,
};
