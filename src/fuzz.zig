const std = @import("std");
const domain_mod = @import("domain/mod.zig");
const email_mod = @import("email/mod.zig");
const user_mod = @import("user/mod.zig");
const manager = @import("dependencies/manager.zig");
const site = @import("runtime/site.zig");
const FeatureSet = @import("dependencies/features.zig").FeatureSet;

const seed = 0x4B414C50;

fn acceptName(name: []const u8) bool {
    user_mod.validateName(name) catch return false;
    return true;
}

fn nameOk(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    if (!(name[0] >= 'a' and name[0] <= 'z') and name[0] != '_') return false;
    for (name[1..]) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return false;
    }
    return true;
}

fn domainOk(name: []const u8) bool {
    if (name.len < 3 or name.len > 253) return false;
    var label_len: usize = 0;
    var dots: usize = 0;
    var prev: u8 = 0;
    for (name) |c| {
        if (c == '.') {
            if (label_len == 0 or prev == '-') return false;
            dots += 1;
            label_len = 0;
            prev = c;
            continue;
        }
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok or (c == '-' and label_len == 0)) return false;
        label_len += 1;
        if (label_len > 63) return false;
        prev = c;
    }
    return label_len != 0 and dots != 0 and prev != '-';
}

fn fillRandom(random: std.Random, buf: []u8) []u8 {
    const len = random.uintLessThan(usize, buf.len + 1);
    for (buf[0..len]) |*c| c.* = random.int(u8);
    return buf[0..len];
}

test "fuzzy account names match the grammar" {
    const fixed_bad = [_][]const u8{ "", "Admin", "../alice", "alice/bob", "-bob", "a b", "..", "this-name-is-way-too-long-for-linux" };
    for (fixed_bad) |name| try std.testing.expect(!acceptName(name));
    try std.testing.expect(acceptName("alice"));
    try std.testing.expect(acceptName("_ok"));

    var prng = std.Random.DefaultPrng.init(seed);
    const random = prng.random();
    var buf: [48]u8 = undefined;
    for (0..200) |_| {
        const name = fillRandom(random, &buf);
        try std.testing.expectEqual(nameOk(name), acceptName(name));
    }
}

test "fuzzy domains reject hyphens, dots, and escapes" {
    const fixed_bad = [_][]const u8{ "example", "-bad.com", "bad-.com", "a..b.com", ".com", "com.", "Example.COM", "a/b.com", "../etc", "ok.-com" };
    for (fixed_bad) |name| {
        try std.testing.expectError(error.InvalidDomain, domain_mod.validateDomain(name));
    }
    try domain_mod.validateDomain("example.com");
    try domain_mod.validateDomain("a.b");

    var prng = std.Random.DefaultPrng.init(seed + 1);
    const random = prng.random();
    var buf: [80]u8 = undefined;
    for (0..200) |_| {
        const name = fillRandom(random, &buf);
        const accepted = if (domain_mod.validateDomain(name)) |_| true else |_| false;
        try std.testing.expectEqual(domainOk(name), accepted);
    }
}

test "fuzzy mailbox locals cannot escape the mail directory" {
    const fixed_bad = [_][]const u8{ "..@example.com", ".@example.com", "a..b@example.com", "../x@example.com", "Alice@example.com", "a@-bad.com", "a@example", "@example.com", "a@b@example.com" };
    for (fixed_bad) |address| {
        try std.testing.expectError(error.InvalidAddress, email_mod.validateAddress(address));
    }
    try email_mod.validateAddress("alice@example.com");
    try email_mod.validateAddress("a.b_c@example.com");

    var prng = std.Random.DefaultPrng.init(seed + 2);
    const random = prng.random();
    var buf: [96]u8 = undefined;
    for (0..200) |_| {
        const address = fillRandom(random, &buf);
        if (email_mod.validateAddress(address)) |_| {
            try std.testing.expect(std.mem.indexOf(u8, address, "..") == null);
            try std.testing.expect(std.mem.indexOf(u8, address, "/") == null);
            try std.testing.expect(std.mem.indexOfScalar(u8, address, '@') != null);
        } else |_| {}
    }
}

fn setFromBits(bits: u4) FeatureSet {
    return .{
        .domain = bits & 1 != 0,
        .email = bits & 2 != 0,
        .php = bits & 4 != 0,
        .node = bits & 8 != 0,
    };
}

fn hasPackage(items: []const manager.Package, name: []const u8) bool {
    for (items) |item| if (std.mem.eql(u8, item.name, name)) return true;
    return false;
}

fn expectPackageSet(set: FeatureSet) !void {
    var buf: [8]manager.Package = undefined;
    const n = try manager.collectPackages(set, &buf);
    const items = buf[0..n];
    try std.testing.expectEqual(set.domain, hasPackage(items, "nginx"));
    try std.testing.expectEqual(set.domain, hasPackage(items, "certbot"));
    try std.testing.expectEqual(set.email, hasPackage(items, "postfix"));
    try std.testing.expectEqual(set.email, hasPackage(items, "dovecot-imapd"));
    try std.testing.expectEqual(set.php, hasPackage(items, "php8.3-cli"));
    try std.testing.expectEqual(set.php, hasPackage(items, "php8.3-fpm"));
    try std.testing.expectEqual(set.node, hasPackage(items, "nodejs"));
    const forbidden = [_][]const u8{ "apache2", "exim4", "exim", "php8.2-fpm", "php8.4-fpm", "php-fpm" };
    for (items) |item| {
        try std.testing.expect(set.isEnabled(item.feature));
        for (forbidden) |name| try std.testing.expect(!std.mem.eql(u8, item.name, name));
    }
}

test "every feature combination installs only its own packages" {
    var bits: u5 = 0;
    while (bits < 16) : (bits += 1) {
        try expectPackageSet(setFromBits(@intCast(bits)));
    }

    var prng = std.Random.DefaultPrng.init(seed + 3);
    const random = prng.random();
    for (0..50) |_| try expectPackageSet(setFromBits(random.int(u4)));
}

fn randomLabel(random: std.Random, buf: []u8) []u8 {
    const len = 1 + random.uintLessThan(usize, 8);
    for (buf[0..len]) |*c| c.* = 'a' + random.uintLessThan(u8, 26);
    return buf[0..len];
}

test "fuzzy nginx config stays on one runtime and one port pair" {
    var prng = std.Random.DefaultPrng.init(seed + 4);
    const random = prng.random();
    var conf: [4096]u8 = undefined;
    for (0..40) |i| {
        var left_buf: [8]u8 = undefined;
        var right_buf: [8]u8 = undefined;
        const left = randomLabel(random, &left_buf);
        const right = randomLabel(random, &right_buf);
        var name_buf: [24]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}.{s}", .{ left, right }) catch unreachable;
        var public_buf: [64]u8 = undefined;
        const public_path = std.fmt.bufPrint(&public_buf, "/home/u{d}/domains/{s}/public", .{ i, name }) catch unreachable;

        const is_php = random.boolean();
        const tls_on = random.boolean();
        const port: i64 = 20000 + @as(i64, @intCast(i));
        const certs: ?site.Certs = if (!tls_on) null else .{
            .fullchain = "/etc/letsencrypt/live/x/fullchain.pem",
            .privkey = "/etc/letsencrypt/live/x/privkey.pem",
        };

        var len: usize = 0;
        try site.append(&conf, &len, name, public_path, is_php, port, certs);
        const text = conf[0..len];

        var server_name: [40]u8 = undefined;
        const needle = std.fmt.bufPrint(&server_name, "server_name {s};", .{name}) catch unreachable;
        try std.testing.expect(std.mem.indexOf(u8, text, needle) != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "listen 80;") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "listen [::]:80;") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "/.well-known/acme-challenge/") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "../") == null);

        var braces: i32 = 0;
        for (text) |c| {
            if (c == '{') braces += 1;
            if (c == '}') braces -= 1;
            try std.testing.expect(braces >= 0);
        }
        try std.testing.expectEqual(@as(i32, 0), braces);

        if (is_php) {
            try std.testing.expect(std.mem.indexOf(u8, text, "unix:/run/php/php8.3-fpm.sock") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "proxy_pass") == null);
            try std.testing.expect(std.mem.indexOf(u8, text, "php8.2") == null);
        } else {
            var proxy: [48]u8 = undefined;
            const proxy_line = std.fmt.bufPrint(&proxy, "proxy_pass http://127.0.0.1:{d};", .{port}) catch unreachable;
            try std.testing.expect(std.mem.indexOf(u8, text, proxy_line) != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "php8.3-fpm") == null);
        }
        if (tls_on) {
            try std.testing.expect(std.mem.indexOf(u8, text, "listen 443 ssl;") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "ssl_certificate ") != null);
            try std.testing.expect(std.mem.indexOf(u8, text, "return 301 https://$host$request_uri;") != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, text, "listen 443") == null);
        }
    }
}
