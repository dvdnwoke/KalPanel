const std = @import("std");
const FeatureSet = @import("../features.zig").FeatureSet;
const Interface = @import("interface.zig");
const domain = @import("domain.zig");
const email = @import("email.zig");
const php = @import("php.zig");
const node = @import("node.zig");

const all_deps = [_]Interface.Dependency{
    domain.dependency,
    email.dependency,
    php.dependency,
    node.dependency,
};

/// Filters to only the dependencies whose feature is enabled for at least one user.
pub fn filterRequired(used: FeatureSet, out: []Interface.Dependency) usize {
    var count: usize = 0;
    for (all_deps) |dep| {
        if (used.isEnabled(dep.feature)) {
            if (count < out.len) {
                out[count] = dep;
                count += 1;
            }
        }
    }
    return count;
}

/// Ensures all required dependencies are present. Returns error if any are missing.
pub fn ensureDependencies(used: FeatureSet) !void {
    var buf: [all_deps.len]Interface.Dependency = undefined;
    const n = filterRequired(used, &buf);
    for (buf[0..n]) |dep| {
        if (!dep.check()) {
            try dep.install();
        }
    }
}
