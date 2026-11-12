const Interface = @import("interface.zig");

pub const dependency = Interface.Dependency{
    .name = "email",
    .feature = .email,
    .commands = &.{"postfix"},
    .packages = &.{ "postfix", "dovecot-imapd" },
};
