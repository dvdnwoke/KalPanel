const Interface = @import("interface.zig");

pub const dependency = Interface.Dependency{
    .name = "php",
    .feature = .php,
    .commands = &.{"php"},
    .packages = &.{ "php8.3-cli", "php8.3-fpm" },
};
