const std = @import("std");
const sqlite = @import("sqlite");
const Db = @import("../database/mod.zig").Db;
const FeatureSet = @import("../dependencies/features.zig").FeatureSet;
const layout_mod = @import("../layout.zig");
const manager = @import("../dependencies/manager.zig");

pub const Apt = struct {
    ctx: *anyopaque,
    isInstalled: *const fn (ctx: *anyopaque, io: std.Io, name: []const u8) bool,
    install: *const fn (ctx: *anyopaque, io: std.Io, names: []const []const u8) anyerror!void,
    remove: *const fn (ctx: *anyopaque, io: std.Io, names: []const []const u8) anyerror!void,
    /// Optional. Live apt updates package lists once before installing.
    prepare: ?*const fn (ctx: *anyopaque, io: std.Io) anyerror!void = null,
};

/// Installs missing packages one at a time and records each one as soon as it
/// succeeds. A second `setup` skips packages that are already installed.
pub fn sync(db: *Db, io: std.Io, used: FeatureSet, apt: Apt) !void {
    var pkgs: [8]manager.Package = undefined;
    const n = try manager.collectPackages(used, &pkgs);
    var missing: [8]manager.Package = undefined;
    var m: usize = 0;
    std.debug.print("setup: checking installed packages\n", .{});
    for (pkgs[0..n]) |pkg| {
        if (apt.isInstalled(apt.ctx, io, pkg.name)) {
            std.debug.print("setup: {s} already installed\n", .{pkg.name});
            continue;
        }
        std.debug.print("setup: {s} missing\n", .{pkg.name});
        missing[m] = pkg;
        m += 1;
    }
    if (m == 0) {
        std.debug.print("setup: nothing to install\n", .{});
        return;
    }
    if (apt.prepare) |prepare| try prepare(apt.ctx, io);
    for (missing[0..m]) |pkg| {
        std.debug.print("setup: installing {s}\n", .{pkg.name});
        try apt.install(apt.ctx, io, &.{pkg.name});
        try db.raw.exec(
            "INSERT OR IGNORE INTO installed_packages (name, feature) VALUES (:name, :feature)",
            .{ .name = sqlite.text(pkg.name), .feature = sqlite.text(@tagName(pkg.feature)) },
        );
        std.debug.print("setup: installed {s}\n", .{pkg.name});
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
        .prepare = livePrepare,
    };
}

fn liveInstalled(ctx: *anyopaque, io: std.Io, name: []const u8) bool {
    _ = ctx;
    const allocator = std.heap.page_allocator;
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "/usr/bin/dpkg-query", "-W", "-f", "${Status}", name },
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) return false;
    return std.mem.indexOf(u8, result.stdout, "install ok installed") != null;
}

fn livePrepare(ctx: *anyopaque, io: std.Io) !void {
    _ = ctx;
    preseedPostfix(io);
    std.debug.print("setup: updating package lists\n", .{});
    try runInherited(io, &.{
        "/usr/bin/env",
        "DEBIAN_FRONTEND=noninteractive",
        "/usr/bin/apt-get",
        "update",
        "-o",
        "DPkg::Lock::Timeout=60",
    });
}

fn liveInstall(ctx: *anyopaque, io: std.Io, names: []const []const u8) !void {
    _ = ctx;
    try liveApt(io, "install", names);
}

fn liveRemove(ctx: *anyopaque, io: std.Io, names: []const []const u8) !void {
    _ = ctx;
    try liveApt(io, "remove", names);
}

fn preseedPostfix(io: std.Io) void {
    const path = "/tmp/kalpanel-postfix.preseed";
    const body = "postfix postfix/main_mailer_type select Internet Site\npostfix postfix/mailname string localhost\n";
    layout_mod.writeFile(io, path, body) catch return;
    runInherited(io, &.{ "/usr/bin/debconf-set-selections", path }) catch {
        std.debug.print("setup: postfix preseed skipped\n", .{});
    };
}

/// One apt invocation. `names` is usually a single package so a stopped setup can continue at the next one.
pub fn fillAptArgv(action: []const u8, names: []const []const u8, out: [][]const u8) error{TooManyPackages}![]const []const u8 {
    const prefix = [_][]const u8{
        "/usr/bin/env",
        "DEBIAN_FRONTEND=noninteractive",
        "NEEDRESTART_MODE=a",
        "/usr/bin/apt-get",
        action,
        "-y",
        "-o",
        "Dpkg::Options::=--force-confdef",
        "-o",
        "Dpkg::Options::=--force-confold",
        "-o",
        "DPkg::Lock::Timeout=60",
    };
    if (prefix.len + names.len > out.len) return error.TooManyPackages;
    @memcpy(out[0..prefix.len], &prefix);
    for (names, 0..) |name, i| out[prefix.len + i] = name;
    return out[0 .. prefix.len + names.len];
}

fn liveApt(io: std.Io, action: []const u8, names: []const []const u8) !void {
    var argv: [28][]const u8 = undefined;
    const args = try fillAptArgv(action, names, &argv);
    try runInherited(io, args);
}

fn runInherited(io: std.Io, argv: []const []const u8) !void {
    std.debug.print("+", .{});
    for (argv) |arg| std.debug.print(" {s}", .{arg});
    std.debug.print("\n", .{});
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .inherit,
        .stdout = .inherit,
        .stderr = .inherit,
    }) catch |err| {
        std.debug.print("setup: could not start {s}: {s}\n", .{ argv[0], @errorName(err) });
        return error.PackageCommandFailed;
    };
    const term = child.wait(io) catch return error.PackageCommandFailed;
    if (!term.success()) {
        std.debug.print("setup: command failed. Run setup again. Packages already installed are skipped.\n", .{});
        return error.PackageCommandFailed;
    }
}
