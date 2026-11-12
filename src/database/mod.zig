const sqlite = @import("sqlite");

pub const Db = struct {
    raw: sqlite.Database,

    /// `path` null opens a private temporary database. Tests pass `":memory:"`.
    pub fn open(path: ?[*:0]const u8) !Db {
        const raw = try sqlite.Database.open(.{ .path = path });
        errdefer raw.close();
        const db = Db{ .raw = raw };
        try db.migrate();
        return db;
    }

    pub fn close(self: Db) void {
        self.raw.close();
    }

    fn migrate(self: Db) !void {
        try self.raw.exec("PRAGMA foreign_keys = ON", .{});
        try self.raw.exec(
            \\CREATE TABLE IF NOT EXISTS users (
            \\  id INTEGER PRIMARY KEY,
            \\  name TEXT NOT NULL UNIQUE,
            \\  role TEXT NOT NULL CHECK (role IN ('admin', 'reseller', 'user')),
            \\  home TEXT NOT NULL
            \\)
        , .{});
        try self.raw.exec(
            \\CREATE TABLE IF NOT EXISTS user_features (
            \\  user_id INTEGER NOT NULL REFERENCES users(id) ON DELETE CASCADE,
            \\  feature TEXT NOT NULL CHECK (feature IN ('domain', 'email', 'php', 'node')),
            \\  PRIMARY KEY (user_id, feature)
            \\)
        , .{});
        try self.raw.exec(
            \\CREATE TABLE IF NOT EXISTS user_flags (
            \\  user_id INTEGER PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
            \\  suspended INTEGER NOT NULL DEFAULT 0
            \\)
        , .{});
        try self.raw.exec(
            \\CREATE TABLE IF NOT EXISTS domains (
            \\  id INTEGER PRIMARY KEY,
            \\  user_id INTEGER NOT NULL REFERENCES users(id),
            \\  name TEXT NOT NULL UNIQUE,
            \\  runtime TEXT NOT NULL CHECK (runtime IN ('php', 'node')),
            \\  public_path TEXT NOT NULL,
            \\  port INTEGER NOT NULL DEFAULT 0,
            \\  suspended INTEGER NOT NULL DEFAULT 0
            \\)
        , .{});
        try self.raw.exec(
            \\CREATE TABLE IF NOT EXISTS emails (
            \\  id INTEGER PRIMARY KEY,
            \\  domain_id INTEGER NOT NULL REFERENCES domains(id),
            \\  local_part TEXT NOT NULL,
            \\  address TEXT NOT NULL UNIQUE,
            \\  password_sha256 TEXT NOT NULL,
            \\  suspended INTEGER NOT NULL DEFAULT 0,
            \\  UNIQUE (domain_id, local_part)
            \\)
        , .{});
        try self.raw.exec(
            \\CREATE TABLE IF NOT EXISTS installed_packages (
            \\  name TEXT PRIMARY KEY,
            \\  feature TEXT NOT NULL
            \\)
        , .{});
        self.raw.exec("ALTER TABLE domains ADD COLUMN tls INTEGER NOT NULL DEFAULT 0", .{}) catch {};
    }
};
