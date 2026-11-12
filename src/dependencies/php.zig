const std = @import("std");
const Interface = @import("interface.zig");
const Feature = @import("../features.zig").Feature;

fn checkPhpDeps() bool {
    return true;
}

fn installPhpDeps() !void {
    std.log.info("Installing PHP runtime dependencies", .{});
}

pub const dependency = Interface.Dependency{
    .name = "php",
    .feature = .php,
    .packages = &.{ "php-fpm", "php-cli" },
    .check = checkPhpDeps,
    .install = installPhpDeps,
};
