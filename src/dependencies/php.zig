const Interface = @import("interface.zig");

pub const dependency = Interface.Dependency{
    .name = "php",
    .feature = .php,
    .commands = &.{"php"},
};
