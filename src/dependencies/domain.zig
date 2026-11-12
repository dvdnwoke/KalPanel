const Interface = @import("interface.zig");

/// Web server for domains. Apache is not used.
/// certbot is the Let's Encrypt client. It is installed only when a domain is in use.
pub const dependency = Interface.Dependency{
    .name = "domain",
    .feature = .domain,
    .commands = &.{"nginx"},
    .packages = &.{ "nginx", "certbot" },
};
