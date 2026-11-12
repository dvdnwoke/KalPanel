const std = @import("std");
const sqlite = @import("sqlite");
const Db = @import("../database/mod.zig").Db;
const Feature = @import("../dependencies/features.zig").Feature;
const FeatureSet = @import("../dependencies/features.zig").FeatureSet;

pub const Role = enum { admin, reseller, user };

/// Who is creating the account. Null is the bootstrap path (first admin).
pub const Actor = enum { admin, reseller };

pub const Request = struct {
    name: []const u8,
    role: Role,
    features: FeatureSet = .{},
    actor: ?Actor = null,
};

pub const Created = struct {
    id: i64,
    role: Role,
    /// Slice of the `home_buf` passed to `create`.
    home: []const u8,
    features: FeatureSet,
};

pub fn validateName(name: []const u8) !void {
    if (name.len == 0 or name.len > 32) return error.InvalidName;
    const first = name[0];
    if (!isLower(first) and first != '_') return error.InvalidName;
    for (name[1..]) |c| {
        if (!isLower(c) and !isDigit(c) and c != '_' and c != '-') return error.InvalidName;
    }
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

pub fn authorize(actor: ?Actor, role: Role) !void {
    const who = actor orelse return;
    switch (who) {
        .admin => {},
        .reseller => if (role != .user) return error.Forbidden,
    }
}

/// Creates the account in SQLite and asks `host` to create the home directory.
/// `host` must provide `home(io, name, buf) ![]const u8` and `rollback(io, name) void`.
/// On Ubuntu, pass `ubuntu.Host`.
pub fn create(db: *Db, io: std.Io, host: anytype, req: Request, home_buf: []u8) !Created {
    try validateName(req.name);
    try authorize(req.actor, req.role);
    if (try nameTaken(db, req.name)) return error.UserExists;

    try db.raw.exec("BEGIN IMMEDIATE", .{});
    errdefer db.raw.exec("ROLLBACK", .{}) catch {};

    const home = try host.home(io, req.name, home_buf);
    errdefer host.rollback(io, req.name);

    try writeFeatures(io, home, req.features);

    try db.raw.exec(
        "INSERT INTO users (name, role, home) VALUES (:name, :role, :home)",
        .{
            .name = sqlite.text(req.name),
            .role = sqlite.text(@tagName(req.role)),
            .home = sqlite.text(home),
        },
    );

    const id = try userId(db, req.name);
    try insertFeatures(db, id, req.features);
    try db.raw.exec("COMMIT", .{});

    return .{
        .id = id,
        .role = req.role,
        .home = home,
        .features = req.features,
    };
}

pub fn featuresFor(db: *Db, user_id: i64) !FeatureSet {
    const query = try db.raw.prepare(
        struct { user_id: i64 },
        struct { feature: sqlite.Text },
        "SELECT feature FROM user_features WHERE user_id = :user_id",
    );
    defer query.finalize();
    try query.bind(.{ .user_id = user_id });
    defer query.reset();

    var set = FeatureSet{};
    while (try query.step()) |row| {
        const feature = parseFeature(row.feature.data) orelse return error.UnknownFeature;
        enable(&set, feature);
    }
    return set;
}

/// Union of features enabled on at least one user. Dependency checks use this.
pub fn featuresInUse(db: *Db) !FeatureSet {
    const query = try db.raw.prepare(
        struct {},
        struct { feature: sqlite.Text },
        "SELECT DISTINCT uf.feature AS feature FROM user_features uf " ++
            "LEFT JOIN user_flags f ON f.user_id = uf.user_id " ++
            "WHERE COALESCE(f.suspended, 0) = 0",
    );
    defer query.finalize();
    try query.bind(.{});
    defer query.reset();

    var set = FeatureSet{};
    while (try query.step()) |row| {
        const feature = parseFeature(row.feature.data) orelse return error.UnknownFeature;
        enable(&set, feature);
    }
    return set;
}

fn nameTaken(db: *Db, name: []const u8) !bool {
    const query = try db.raw.prepare(
        struct { name: sqlite.Text },
        struct { id: i64 },
        "SELECT id FROM users WHERE name = :name",
    );
    defer query.finalize();
    try query.bind(.{ .name = sqlite.text(name) });
    defer query.reset();
    return (try query.step()) != null;
}

fn userId(db: *Db, name: []const u8) !i64 {
    const query = try db.raw.prepare(
        struct { name: sqlite.Text },
        struct { id: i64 },
        "SELECT id FROM users WHERE name = :name",
    );
    defer query.finalize();
    try query.bind(.{ .name = sqlite.text(name) });
    defer query.reset();
    const row = (try query.step()) orelse return error.UserNotFound;
    return row.id;
}

fn insertFeatures(db: *Db, user_id: i64, features: FeatureSet) !void {
    const insert = try db.raw.prepare(
        struct { user_id: i64, feature: sqlite.Text },
        void,
        "INSERT INTO user_features (user_id, feature) VALUES (:user_id, :feature)",
    );
    defer insert.finalize();

    if (features.domain) try insert.exec(.{ .user_id = user_id, .feature = sqlite.text("domain") });
    if (features.email) try insert.exec(.{ .user_id = user_id, .feature = sqlite.text("email") });
    if (features.php) try insert.exec(.{ .user_id = user_id, .feature = sqlite.text("php") });
    if (features.node) try insert.exec(.{ .user_id = user_id, .feature = sqlite.text("node") });
}

fn writeFeatures(io: std.Io, home: []const u8, features: FeatureSet) !void {
    var body: [64]u8 = undefined;
    var len: usize = 0;
    len = appendFeature(&body, len, "domain", features.domain);
    len = appendFeature(&body, len, "email", features.email);
    len = appendFeature(&body, len, "php", features.php);
    len = appendFeature(&body, len, "node", features.node);

    var dir = try std.Io.Dir.openDirAbsolute(io, home, .{});
    defer dir.close(io);
    try dir.createDirPath(io, ".kalpanel");
    try dir.writeFile(io, .{
        .sub_path = ".kalpanel/features",
        .data = body[0..len],
    });
}

fn appendFeature(buf: []u8, len: usize, name: []const u8, enabled: bool) usize {
    if (!enabled) return len;
    @memcpy(buf[len..][0..name.len], name);
    var next = len + name.len;
    buf[next] = '\n';
    next += 1;
    return next;
}

fn enable(set: *FeatureSet, feature: Feature) void {
    switch (feature) {
        .domain => set.domain = true,
        .email => set.email = true,
        .php => set.php = true,
        .node => set.node = true,
    }
}

fn parseFeature(name: []const u8) ?Feature {
    if (std.mem.eql(u8, name, "domain")) return .domain;
    if (std.mem.eql(u8, name, "email")) return .email;
    if (std.mem.eql(u8, name, "php")) return .php;
    if (std.mem.eql(u8, name, "node")) return .node;
    return null;
}

pub const Account = struct {
    id: i64,
    role: Role,
    suspended: bool,
    home: []const u8,
};

pub fn parseRole(name: []const u8) ?Role {
    if (std.mem.eql(u8, name, "admin")) return .admin;
    if (std.mem.eql(u8, name, "reseller")) return .reseller;
    if (std.mem.eql(u8, name, "user")) return .user;
    return null;
}

pub fn lookup(db: *Db, name: []const u8, home_buf: []u8) !?Account {
    const query = try db.raw.prepare(
        struct { name: sqlite.Text },
        struct { id: i64, role: sqlite.Text, home: sqlite.Text, suspended: i64 },
        "SELECT u.id AS id, u.role AS role, u.home AS home, COALESCE(f.suspended, 0) AS suspended " ++
            "FROM users u LEFT JOIN user_flags f ON f.user_id = u.id WHERE u.name = :name",
    );
    defer query.finalize();
    try query.bind(.{ .name = sqlite.text(name) });
    defer query.reset();
    const row = (try query.step()) orelse return null;
    if (row.home.data.len > home_buf.len) return error.HomeTooLong;
    @memcpy(home_buf[0..row.home.data.len], row.home.data);
    return .{
        .id = row.id,
        .role = parseRole(row.role.data) orelse return error.UnknownRole,
        .suspended = row.suspended != 0,
        .home = home_buf[0..row.home.data.len],
    };
}

pub fn setSuspended(db: *Db, name: []const u8, suspended: bool) !void {
    var home_buf: [512]u8 = undefined;
    const account = (try lookup(db, name, &home_buf)) orelse return error.UserNotFound;
    const flag: i64 = if (suspended) 1 else 0;
    try db.raw.exec(
        "INSERT INTO user_flags (user_id, suspended) VALUES (?, ?) ON CONFLICT(user_id) DO UPDATE SET suspended = excluded.suspended",
        .{ account.id, flag },
    );
}

const ListedUser = struct {
    id: i64,
    suspended: i64,
    name_len: usize,
    role_len: usize,
    name: [32]u8 = undefined,
    role: [16]u8 = undefined,
};

/// One line per account, ordered by name. Passwords are never printed.
pub fn list(db: *Db, out: anytype) !void {
    var rows: [128]ListedUser = undefined;
    const n = try collectUsers(db, &rows);
    if (n == 0) {
        try out.print("no users\n", .{});
        return;
    }
    for (rows[0..n]) |row| {
        const features = try featuresFor(db, row.id);
        var feat_buf: [40]u8 = undefined;
        const feats = formatFeatures(features, &feat_buf);
        try out.print("user {s} role {s} suspended {d} features {s}\n", .{
            row.name[0..row.name_len],
            row.role[0..row.role_len],
            row.suspended,
            feats,
        });
    }
}

/// Removes the account row and the home directory. Domains must already be gone.
pub fn remove(db: *Db, io: std.Io, host: anytype, name: []const u8) !void {
    var home_buf: [512]u8 = undefined;
    if ((try lookup(db, name, &home_buf)) == null) return error.UserNotFound;
    try db.raw.exec("DELETE FROM users WHERE name = :name", .{ .name = sqlite.text(name) });
    host.rollback(io, name);
}

fn collectUsers(db: *Db, rows: []ListedUser) !usize {
    const query = try db.raw.prepare(
        struct {},
        struct { id: i64, name: sqlite.Text, role: sqlite.Text, suspended: i64 },
        "SELECT u.id AS id, u.name AS name, u.role AS role, COALESCE(f.suspended, 0) AS suspended " ++
            "FROM users u LEFT JOIN user_flags f ON f.user_id = u.id ORDER BY u.name",
    );
    defer query.finalize();
    try query.bind(.{});
    defer query.reset();
    var n: usize = 0;
    while (try query.step()) |row| {
        if (n >= rows.len) return error.TooManyUsers;
        if (row.name.data.len > rows[n].name.len or row.role.data.len > rows[n].role.len) return error.InvalidName;
        rows[n] = .{
            .id = row.id,
            .suspended = row.suspended,
            .name_len = row.name.data.len,
            .role_len = row.role.data.len,
        };
        @memcpy(rows[n].name[0..row.name.data.len], row.name.data);
        @memcpy(rows[n].role[0..row.role.data.len], row.role.data);
        n += 1;
    }
    return n;
}

fn formatFeatures(features: FeatureSet, buf: []u8) []const u8 {
    var len: usize = 0;
    len = appendFeat(buf, len, features.domain, "domain");
    len = appendFeat(buf, len, features.email, "email");
    len = appendFeat(buf, len, features.php, "php");
    len = appendFeat(buf, len, features.node, "node");
    if (len == 0) {
        @memcpy(buf[0..4], "none");
        return buf[0..4];
    }
    return buf[0..len];
}

fn appendFeat(buf: []u8, len: usize, on: bool, name: []const u8) usize {
    if (!on) return len;
    var next = len;
    if (next != 0) {
        buf[next] = ',';
        next += 1;
    }
    @memcpy(buf[next..][0..name.len], name);
    return next + name.len;
}
