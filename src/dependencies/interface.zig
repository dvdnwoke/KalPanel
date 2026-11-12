const std = @import("std");
const Feature = @import("../features.zig").Feature;

pub const Dependency = struct {
    name: []const u8,
    feature: Feature,
    /// Packages or tools that must be present
    packages: []const []const u8,
    check: *const fn () bool,
    install: *const fn () !void,
};
