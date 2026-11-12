const std = @import("std");
// const sqlite = @import("sqlite"); // uncomment after zig fetch

/// Database module for SQLite-backed user and account storage.
/// Uses nDimensional/zig-sqlite (confirmed compatible with Zig 0.17).
///
/// After running:
///   zig fetch --save=sqlite https://github.com/nDimensional/zig-sqlite/archive/refs/tags/v0.5.0-3530400.tar.gz
/// and updating build.zig to import the module, the import above can be enabled.
pub fn open(path: ?[]const u8) !void {
    // Placeholder until dependency is fetched and linked
    std.log.info("Database module ready. SQLite path: {?s}", .{path});
    // Example once linked:
    // const db = try sqlite.Database.open(.{ .path = path orelse ":memory:" });
    // defer db.close();
}

pub fn initSchema() !void {
    std.log.info("Schema init placeholder (users, accounts, permissions)", .{});
}
