const std = @import("std");
const sqlite = @import("sqlite");
const Db = @import("../database/mod.zig").Db;
const users = @import("../user/mod.zig");
const layout_mod = @import("../layout.zig");
const php = @import("../runtime/php.zig");
const node = @import("../runtime/node.zig");

pub const Runtime = enum { php, node };

pub fn validateDomain(name: []const u8) !void {
    if (name.len < 3 or name.len > 253) return error.InvalidDomain;
    if (name[0] == '.' or name[name.len - 1] == '.') return error.InvalidDomain;
    var label_len: usize = 0;
    var dots: usize = 0;
    for (name) |c| {
        if (c == '.') {
            if (label_len == 0) return error.InvalidDomain;
            dots += 1;
            label_len = 0;
            continue;
        }
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-';
        if (!ok) return error.InvalidDomain;
        label_len += 1;
        if (label_len > 63) return error.InvalidDomain;
    }
    if (label_len == 0 or dots == 0) return error.InvalidDomain;
}

pub fn parseRuntime(name: []const u8) ?Runtime {
    if (std.mem.eql(u8, name, "php")) return .php;
    if (std.mem.eql(u8, name, "node")) return .node;
    return null;
}

pub fn create(db: *Db, io: std.Io, layout: layout_mod.Layout, user_name: []const u8, domain: []const u8, runtime: Runtime) !void {
    var home_buf: [512]u8 = undefined;
    const account = (try users.lookup(db, user_name, &home_buf)) orelse return error.UserNotFound;
    if (account.suspended) return error.UserSuspended;

    const features = try users.featuresFor(db, account.id);
    if (!features.domain) return error.FeatureNotEnabled;
    if (runtime == .php and !features.php) return error.FeatureNotEnabled;
    if (runtime == .node and !features.node) return error.FeatureNotEnabled;
    try validateDomain(domain);
    if (try domainTaken(db, domain)) return error.DomainExists;

    var public_buf: [512]u8 = undefined;
    const public_path = try std.fmt.bufPrint(&public_buf, "{s}/domains/{s}/public", .{ account.home, domain });
    const port: i64 = if (runtime == .node) try nextNodePort(db) else 0;

    try db.raw.exec(
        "INSERT INTO domains (user_id, name, runtime, public_path, port) VALUES (:user_id, :name, :runtime, :public_path, :port)",
        .{
            .user_id = account.id,
            .name = sqlite.text(domain),
            .runtime = sqlite.text(@tagName(runtime)),
            .public_path = sqlite.text(public_path),
            .port = port,
        },
    );

    switch (runtime) {
        .php => {
            var file_buf: [512]u8 = undefined;
            const file_path = try std.fmt.bufPrint(&file_buf, "{s}/index.php", .{public_path});
            try layout_mod.writeFile(io, file_path, php.index_php);
        },
        .node => {
            var file_buf: [512]u8 = undefined;
            const file_path = try std.fmt.bufPrint(&file_buf, "{s}/server.js", .{public_path});
            try layout_mod.writeFile(io, file_path, node.server_js);
        },
    }
    try reload(db, io, layout);
}

pub fn suspendName(db: *Db, io: std.Io, layout: layout_mod.Layout, domain: []const u8) !void {
    if (!try domainTaken(db, domain)) return error.DomainNotFound;
    try db.raw.exec(
        "UPDATE domains SET suspended = 1 WHERE name = :name",
        .{ .name = sqlite.text(domain) },
    );
    try reload(db, io, layout);
}

pub fn reload(db: *Db, io: std.Io, layout: layout_mod.Layout) !void {
    const query = try db.raw.prepare(
        struct {},
        struct {
            name: sqlite.Text,
            runtime: sqlite.Text,
            public_path: sqlite.Text,
            port: i64,
            suspended: i64,
            user_suspended: i64,
            user_name: sqlite.Text,
        },
        "SELECT d.name AS name, d.runtime AS runtime, d.public_path AS public_path, d.port AS port, d.suspended AS suspended, COALESCE(f.suspended, 0) AS user_suspended, u.name AS user_name " ++
            "FROM domains d JOIN users u ON u.id = d.user_id LEFT JOIN user_flags f ON f.user_id = u.id",
    );
    defer query.finalize();
    try query.bind(.{});
    defer query.reset();

    while (try query.step()) |row| {
        const active = row.suspended == 0 and row.user_suspended == 0;
        var avail: [512]u8 = undefined;
        var enabled: [512]u8 = undefined;
        var unit: [512]u8 = undefined;
        const avail_rel = try std.fmt.bufPrint(&avail, "etc/nginx/sites-available/{s}.conf", .{row.name.data});
        var avail_path: [512]u8 = undefined;
        const avail_full = try layout.resolve(&avail_path, avail_rel);
        const enabled_rel = try std.fmt.bufPrint(&enabled, "etc/nginx/sites-enabled/{s}.conf", .{row.name.data});
        var enabled_path: [512]u8 = undefined;
        const enabled_full = try layout.resolve(&enabled_path, enabled_rel);
        const unit_rel = try std.fmt.bufPrint(&unit, "etc/systemd/system/kalpanel-{s}.service", .{row.name.data});
        var unit_path: [512]u8 = undefined;
        const unit_full = try layout.resolve(&unit_path, unit_rel);

        if (!active) {
            layout_mod.removeFile(io, enabled_full);
            layout_mod.removeFile(io, unit_full);
            continue;
        }

        var conf: [2048]u8 = undefined;
        var len: usize = 0;
        const runtime = parseRuntime(row.runtime.data) orelse return error.UnknownRuntime;
        switch (runtime) {
            .php => try php.appendServer(&conf, &len, row.name.data, row.public_path.data),
            .node => {
                try node.appendServer(&conf, &len, row.name.data, row.port);
                var unit_body: [1024]u8 = undefined;
                var unit_len: usize = 0;
                try node.appendUnit(&unit_body, &unit_len, row.name.data, row.public_path.data, row.port, row.user_name.data);
                try layout_mod.writeFile(io, unit_full, unit_body[0..unit_len]);
            },
        }
        try layout_mod.writeFile(io, avail_full, conf[0..len]);
        try layout_mod.writeFile(io, enabled_full, conf[0..len]);
    }
}

fn domainTaken(db: *Db, name: []const u8) !bool {
    const query = try db.raw.prepare(
        struct { name: sqlite.Text },
        struct { id: i64 },
        "SELECT id FROM domains WHERE name = :name",
    );
    defer query.finalize();
    try query.bind(.{ .name = sqlite.text(name) });
    defer query.reset();
    return (try query.step()) != null;
}

fn nextNodePort(db: *Db) !i64 {
    const query = try db.raw.prepare(
        struct {},
        struct { n: i64 },
        "SELECT COUNT(*) AS n FROM domains WHERE runtime = 'node'",
    );
    defer query.finalize();
    try query.bind(.{});
    defer query.reset();
    const row = (try query.step()) orelse return error.Database;
    return 20000 + row.n;
}
