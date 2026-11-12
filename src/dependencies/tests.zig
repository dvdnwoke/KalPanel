const std = @import("std");
const Feature = @import("../features.zig").Feature;
const FeatureSet = @import("../features.zig").FeatureSet;
const manager = @import("manager.zig");

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
    var buf: [8]manager.Interface.Dependency = undefined; // note: need to import Interface
    // Wait, fix later if needed
    const n = manager.filterRequired(set, &buf);
    try std.testing.expect(n == 2);
    // names should be domain and php
    var found_domain = false;
    var found_php = false;
    for (buf[0..n]) |d| {
        if (std.mem.eql(u8, d.name, "domain")) found_domain = true;
        if (std.mem.eql(u8, d.name, "php")) found_php = true;
    }
    try std.testing.expect(found_domain and found_php);
}

test "no users using feature means no dep" {
    const set = FeatureSet{}; // all false
    var buf: [8]manager.Interface.Dependency = undefined;
    const n = manager.filterRequired(set, &buf);
    try std.testing.expect(n == 0);
}

// Basic "fuzzy" / randomized selection test
test "randomized feature selection" {
    var prng = std.Random.DefaultPrng.init(42);
    const random = prng.random();
    for (0..20) |_| {
        var set = FeatureSet{};
        set.domain = random.boolean();
        set.email = random.boolean();
        set.php = random.boolean();
        set.node = random.boolean();

        var buf: [8]manager.Interface.Dependency = undefined;
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
