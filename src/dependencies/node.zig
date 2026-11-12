const Interface = @import("interface.zig");

pub const dependency = Interface.Dependency{
    .name = "node",
    .feature = .node,
    .commands = &.{"node"},
    .packages = &.{"nodejs"},
};
