const std = @import("std");
const sqlite = @import("sqlite");
const Db = @import("../database/mod.zig").Db;
const FeatureSet = @import("../dependencies/features.zig").FeatureSet;
const manager = @import("../dependencies/manager.zig");

pub const Apt = struct {
    ctx: *anyopaque,
    isInstalled: *const fn (ctx: *anyopaque, io: std.Io, name: []const u8) bool,
    install: *const fn (ctx: *anyopaque, io: std.Io, names: []const []const u8) anyerror!void,
    remove: *const fn (ctx: *anyopaque, io: std.Io, names: []const []const u8) anyerror!void,
};

/// Installs missing packages for features that are actually in use.
/// Packages that are already on the system are not recorded, so uninstall will not remove them.
pub fn sync(db: *Db, io: std.Io, used: FeatureSet, apt: Apt) !void {
    var pkgs: [8]manager.Package = undefined;
    const n = manager.collectPackages(used, &pkgs);
    var missing: [8][]const u8 = undefined;
    var missing_features: [8][]const u8 = undefined;
    var m: usize = 0;
    for (pkgs[0..n]) |pkg| {
        if (apt.isInstalled(apt.ctx, io, pkg.name)) continue;
        missing[m] = pkg.name;
        missing_features[m] = @tagName(pkg.feature);
        m += 1;
    }
    if (m == 0) return;
    try apt.install(apt.ctx, io, missing[0..m]);
    for (missing[0..m], missing_features[0..m]) |name, feature| {
        try db.raw.exec(
            "INSERT OR IGNORE INTO installed_packages (name, feature) VALUES (:name, :feature)",
            .{ .name = sqlite.text(name), .feature = sqlite.text(feature) },
        );
    }
}

/// Removes only packages this program installed.
pub fn uninstall(db: *Db, io: std.Io, apt: Apt) !void {
    var storage: [16 * 64]u8 = undefined;
    var used_bytes: usize = 0;
    var names: [16][]const u8 = undefined;
    var count: usize = 0;

    const query = try db.raw.prepare(
        struct {},
        struct { name: sqlite.Text },
        "SELECT name FROM installed_packages",
    );
    defer query.finalize();
    try query.bind(.{});
    defer query.reset();
    while (try query.step()) |row| {
        if (count >= names.len) return error.TooManyPackages;
        if (used_bytes + row.name.data.len > storage.len) return error.TooManyPackages;
        @memcpy(storage[used_bytes..][0..row.name.data.len], row.name.data);
        names[count] = storage[used_bytes..][0..row.name.data.len];
        used_bytes += row.name.data.len;
        count += 1;
    }
    if (count == 0) return;
    try apt.remove(apt.ctx, io, names[0..count]);
    try db.raw.exec("DELETE FROM installed_packages", .{});
}

pub fn live(ctx: *anyopaque) Apt {
    return .{
        .ctx = ctx,
        .isInstalled = liveInstalled,
        .install = liveInstall,
        .remove = liveRemove,
    };
}

fn liveInstalled(ctx: *anyopaque, io: std.Io, name: []const u8) bool {
    _ = ctx;
    const allocator = std.heap.page_allocator;
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "dpkg-query", "-W", "-f", "${Status}", name },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) return false;
    return std.mem.indexOf(u8, result.stdout, "install ok installed") != null;
}

fn liveInstall(ctx: *anyopaque, io: std.Io, names: []const []const u8) !void {
    _ = ctx;
    try liveApt(io, "install", names);
}

fn liveRemove(ctx: *anyopaque, io: std.Io, names: []const []const u8) !void {
    _ = ctx;
    try liveApt(io, "remove", names);
}

fn liveApt(io: std.Io, action: []const u8, names: []const []const u8) !void {
    var argv: [14][]const u8 = undefined;
    argv[0] = "env";
    argv[1] = "DEBIAN_FRONTEND=noninteractive";
    argv[2] = "apt-get";
    argv[3] = action;
    argv[4] = "-y";
    if (names.len + 5 > argv.len) return error.TooManyPackages;
    for (names, 0..) |name, i| argv[5 + i] = name;
    const allocator = std.heap.page_allocator;
    const result = std.process.run(allocator, io, .{
        .argv = argv[0 .. names.len + 5],
    }) catch return error.PackageCommandFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) return error.PackageCommandFailed;
}
