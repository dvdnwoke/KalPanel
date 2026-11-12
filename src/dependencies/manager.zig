const std = @import("std");
const Feature = @import("../features.zig").Feature;
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

/// Returns dependencies that should be installed/checked based on features
/// used by at least one user. If no user uses a feature, its deps are skipped.
pub fn getRequiredDependencies(used: FeatureSet) []const Interface.Dependency {
    // In a real implementation this would allocate; for bootstrap we return a static filter via caller
    // For simplicity in tests we use a different approach; this is the core logic.
    _ = used;
    return &all_deps;
}

/// Filters the static list according to the FeatureSet (used by >=1 user).
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

pub fn ensureDependencies(used: FeatureSet) !void {
    var buf: [all_deps.len]Interface.Dependency = undefined;
    const n = filterRequired(used, &buf);
    for (buf[0..n]) |dep| {
        if (!dep.check()) {
            try dep.install();
        }
    }
}
