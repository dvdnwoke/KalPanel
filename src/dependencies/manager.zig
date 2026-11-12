const Feature = @import("features.zig").Feature;
const FeatureSet = @import("features.zig").FeatureSet;
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

/// A required command that is not installed for an enabled feature.
pub const Gap = struct {
    name: []const u8,
    feature: Feature,
    command: []const u8,
};

/// Apt package setup may install for an enabled feature.
pub const Package = struct {
    feature: Feature,
    name: []const u8,
};

/// Dependencies whose feature is enabled for at least one user.
pub fn filterRequired(used: FeatureSet, out: []Interface.Dependency) usize {
    var count: usize = 0;
    for (all_deps) |dep| {
        if (!used.isEnabled(dep.feature)) continue;
        if (count < out.len) {
            out[count] = dep;
            count += 1;
        }
    }
    return count;
}

/// Missing commands for enabled features only. Other modules call this before they act.
pub fn collectMissing(used: FeatureSet, out: []Gap) usize {
    var count: usize = 0;
    for (all_deps) |dep| {
        if (!used.isEnabled(dep.feature)) continue;
        for (dep.commands) |cmd| {
            if (Interface.commandExists(cmd)) continue;
            if (count < out.len) {
                out[count] = .{
                    .name = dep.name,
                    .feature = dep.feature,
                    .command = cmd,
                };
                count += 1;
            }
        }
    }
    return count;
}

/// True when every command required by an enabled feature is on PATH.
pub fn ready(used: FeatureSet) bool {
    var gaps: [8]Gap = undefined;
    return collectMissing(used, &gaps) == 0;
}

/// Fails when any enabled feature is missing a required command.
pub fn ensureDependencies(used: FeatureSet) Interface.InstallError!void {
    if (!ready(used)) return error.DependenciesNotInstalled;
}

/// One PHP version (8.3) and one Node package. Unused features contribute nothing.
/// Returns `error.PackageListTooSmall` instead of quietly dropping a package.
pub fn collectPackages(used: FeatureSet, out: []Package) error{PackageListTooSmall}!usize {
    var count: usize = 0;
    for (all_deps) |dep| {
        if (!used.isEnabled(dep.feature)) continue;
        for (dep.packages) |name| {
            if (count >= out.len) return error.PackageListTooSmall;
            out[count] = .{ .feature = dep.feature, .name = name };
            count += 1;
        }
    }
    return count;
}
