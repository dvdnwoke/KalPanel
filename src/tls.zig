const std = @import("std");
const sqlite = @import("sqlite");
const Db = @import("database/mod.zig").Db;
const layout_mod = @import("layout.zig");

pub const Issuer = struct {
    ctx: *anyopaque,
    issue: *const fn (ctx: *anyopaque, io: std.Io, domain: []const u8, webroot: []const u8, email: []const u8, config_dir: []const u8) anyerror!void,
    renew: *const fn (ctx: *anyopaque, io: std.Io, config_dir: []const u8) anyerror!void,
};

pub const renew_hook =
    \\#!/bin/sh
    \\nginx -s reload 2>/dev/null || systemctl reload nginx
    \\systemctl reload dovecot 2>/dev/null || true
    \\systemctl reload postfix 2>/dev/null || true
    \\
;

pub fn live(ctx: *anyopaque) Issuer {
    return .{ .ctx = ctx, .issue = liveIssue, .renew = liveRenew };
}

pub fn validateContact(email: []const u8) !void {
    const at = std.mem.indexOfScalar(u8, email, '@') orelse return error.InvalidEmail;
    if (at == 0 or at + 1 >= email.len) return error.InvalidEmail;
    if (std.mem.indexOfScalar(u8, email[at + 1 ..], '.') == null) return error.InvalidEmail;
    if (std.mem.indexOfScalar(u8, email[0..at], ' ') != null) return error.InvalidEmail;
}

pub fn configDir(layout: layout_mod.Layout, buf: []u8) ![]const u8 {
    return layout.resolve(buf, "etc/letsencrypt");
}

pub fn fullchainPath(layout: layout_mod.Layout, buf: []u8, domain: []const u8) ![]const u8 {
    var rel: [320]u8 = undefined;
    const path = try std.fmt.bufPrint(&rel, "etc/letsencrypt/live/{s}/fullchain.pem", .{domain});
    return layout.resolve(buf, path);
}

pub fn privkeyPath(layout: layout_mod.Layout, buf: []u8, domain: []const u8) ![]const u8 {
    var rel: [320]u8 = undefined;
    const path = try std.fmt.bufPrint(&rel, "etc/letsencrypt/live/{s}/privkey.pem", .{domain});
    return layout.resolve(buf, path);
}

/// First active domain that already has a certificate. Mail uses this name.
pub fn firstDomain(db: *Db, name_buf: []u8) !?[]const u8 {
    const query = try db.raw.prepare(
        struct {},
        struct { name: sqlite.Text },
        "SELECT name AS name FROM domains WHERE tls = 1 AND suspended = 0 ORDER BY name LIMIT 1",
    );
    defer query.finalize();
    try query.bind(.{});
    defer query.reset();
    const row = (try query.step()) orelse return null;
    if (row.name.data.len > name_buf.len) return error.NameTooLong;
    @memcpy(name_buf[0..row.name.data.len], row.name.data);
    return name_buf[0..row.name.data.len];
}

pub fn installHook(io: std.Io, layout: layout_mod.Layout) !void {
    var path_buf: [512]u8 = undefined;
    const path = try layout.resolve(&path_buf, "etc/letsencrypt/renewal-hooks/deploy/kalpanel");
    try layout_mod.writeFile(io, path, renew_hook);
    if (!layout.system()) return;
    const allocator = std.heap.page_allocator;
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "chmod", "755", path },
    }) catch return error.CommandFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) return error.CommandFailed;
}

fn liveIssue(ctx: *anyopaque, io: std.Io, domain: []const u8, webroot: []const u8, email: []const u8, config_dir: []const u8) !void {
    _ = ctx;
    var work_buf: [512]u8 = undefined;
    var logs_buf: [512]u8 = undefined;
    const work = try std.fmt.bufPrint(&work_buf, "{s}/work", .{config_dir});
    const logs = try std.fmt.bufPrint(&logs_buf, "{s}/logs", .{config_dir});
    try run(io, &.{
        "certbot",
        "certonly",
        "--non-interactive",
        "--agree-tos",
        "--email",
        email,
        "--webroot",
        "-w",
        webroot,
        "-d",
        domain,
        "--config-dir",
        config_dir,
        "--work-dir",
        work,
        "--logs-dir",
        logs,
        "--keep-until-expiring",
    });
}

fn liveRenew(ctx: *anyopaque, io: std.Io, config_dir: []const u8) !void {
    _ = ctx;
    var work_buf: [512]u8 = undefined;
    var logs_buf: [512]u8 = undefined;
    const work = try std.fmt.bufPrint(&work_buf, "{s}/work", .{config_dir});
    const logs = try std.fmt.bufPrint(&logs_buf, "{s}/logs", .{config_dir});
    try run(io, &.{
        "certbot",
        "renew",
        "--non-interactive",
        "--config-dir",
        config_dir,
        "--work-dir",
        work,
        "--logs-dir",
        logs,
    });
}

fn run(io: std.Io, argv: []const []const u8) !void {
    const allocator = std.heap.page_allocator;
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch return error.CommandFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) return error.CommandFailed;
}
