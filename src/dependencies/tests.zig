const std = @import("std");
const Feature = @import("features.zig").Feature;
const FeatureSet = @import("features.zig").FeatureSet;
const manager = @import("manager.zig");
const Interface = @import("interface.zig");
const domain = @import("domain.zig");
const email = @import("email.zig");
const php = @import("php.zig");
const node = @import("node.zig");

fn expectOnly(commands: []const []const u8, expected: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 1), commands.len);
    try std.testing.expectEqualStrings(expected, commands[0]);
}

test "feature set from list" {
    const features = [_]Feature{ .domain, .php };
    const set = FeatureSet.fromUserFeatures(&features);
    try std.testing.expect(set.domain);
    try std.testing.expect(!set.email);
    try std.testing.expect(set.php);
    try std.testing.expect(!set.node);
}

test "only used features produce dependencies" {
    const set = FeatureSet{ .domain = true, .email = false, .php = true, .node = false };
    var buf: [8]Interface.Dependency = undefined;
    const n = manager.filterRequired(set, &buf);
    try std.testing.expectEqual(@as(usize, 2), n);

    var found_domain = false;
    var found_php = false;
    for (buf[0..n]) |d| {
        if (std.mem.eql(u8, d.name, "domain")) found_domain = true;
        if (std.mem.eql(u8, d.name, "php")) found_php = true;
    }
    try std.testing.expect(found_domain and found_php);
}

test "no users using feature means no dep" {
    const set = FeatureSet{};
    var buf: [8]Interface.Dependency = undefined;
    const n = manager.filterRequired(set, &buf);
    try std.testing.expectEqual(@as(usize, 0), n);
}

test "randomized feature selection" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (0..50) |_| {
        var set = FeatureSet{};
        set.domain = random.boolean();
        set.email = random.boolean();
        set.php = random.boolean();
        set.node = random.boolean();

        var buf: [8]Interface.Dependency = undefined;
        const n = manager.filterRequired(set, &buf);

        var expected: usize = 0;
        if (set.domain) expected += 1;
        if (set.email) expected += 1;
        if (set.php) expected += 1;
        if (set.node) expected += 1;
        try std.testing.expectEqual(expected, n);

        for (buf[0..n]) |d| {
            try std.testing.expect(set.isEnabled(d.feature));
        }
    }
}

test "each feature checks only its own binary" {
    try expectOnly(domain.dependency.commands, "nginx");
    try expectOnly(email.dependency.commands, "postfix");
    try expectOnly(php.dependency.commands, "php");
    try expectOnly(node.dependency.commands, "node");

    const forbidden = [_][]const u8{ "apache2", "exim4", "exim", "php-fpm", "nodejs" };
    const catalogs = [_][]const []const u8{
        domain.dependency.commands,
        email.dependency.commands,
        php.dependency.commands,
        node.dependency.commands,
    };
    for (catalogs) |commands| {
        for (commands) |cmd| {
            for (forbidden) |name| {
                try std.testing.expect(!std.mem.eql(u8, cmd, name));
            }
        }
    }
}

test "commandExists finds sh and rejects a missing binary" {
    try std.testing.expect(Interface.commandExists("sh"));
    try std.testing.expect(!Interface.commandExists("kalpanel-missing-bin"));
}

test "every listed command is required" {
    const mixed = Interface.Dependency{
        .name = "mixed",
        .feature = .domain,
        .commands = &.{ "sh", "kalpanel-missing-bin" },
    };
    try std.testing.expect(!mixed.check());

    var missing_buf: [4][]const u8 = undefined;
    const n = mixed.missing(&missing_buf);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("kalpanel-missing-bin", missing_buf[0]);

    const present = Interface.Dependency{
        .name = "shell",
        .feature = .domain,
        .commands = &.{"sh"},
    };
    try std.testing.expect(present.check());
}

test "disabled features are not reported missing" {
    const set = FeatureSet{};
    var gaps: [8]manager.Gap = undefined;
    try std.testing.expectEqual(@as(usize, 0), manager.collectMissing(set, &gaps));
    try manager.ensureDependencies(set);
    try std.testing.expect(manager.ready(set));
}

test "enabled feature reports its own missing command" {
    const set = FeatureSet{ .domain = true };
    var gaps: [8]manager.Gap = undefined;
    const n = manager.collectMissing(set, &gaps);
    if (Interface.commandExists("nginx")) {
        try std.testing.expectEqual(@as(usize, 0), n);
        try manager.ensureDependencies(set);
    } else {
        try std.testing.expectEqual(@as(usize, 1), n);
        try std.testing.expectEqualStrings("domain", gaps[0].name);
        try std.testing.expectEqualStrings("nginx", gaps[0].command);
        try std.testing.expect(gaps[0].feature == .domain);
        try std.testing.expectError(error.DependenciesNotInstalled, manager.ensureDependencies(set));
        try std.testing.expect(!manager.ready(set));
    }
}

test "a disabled feature is omitted even when its binary is absent" {
    if (Interface.commandExists("postfix")) return;
    const set = FeatureSet{ .domain = Interface.commandExists("nginx") };
    var gaps: [8]manager.Gap = undefined;
    const n = manager.collectMissing(set, &gaps);
    for (gaps[0..n]) |gap| {
        try std.testing.expect(gap.feature != .email);
        try std.testing.expect(!std.mem.eql(u8, gap.command, "postfix"));
    }
}
