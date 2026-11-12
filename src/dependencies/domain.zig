const Interface = @import("interface.zig");

/// Web server for domains. Apache is not used.
pub const dependency = Interface.Dependency{
    .name = "domain",
    .feature = .domain,
    .commands = &.{"nginx"},
};
