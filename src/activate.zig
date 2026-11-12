const std = @import("std");
const sqlite = @import("sqlite");
const Db = @import("database/mod.zig").Db;
const layout_mod = @import("layout.zig");
const tls_mod = @import("tls.zig");

pub const Runner = struct {
    ctx: *anyopaque,
    exec: *const fn (ctx: *anyopaque, io: std.Io, argv: []const []const u8) anyerror!void,
};

pub fn live(ctx: *anyopaque) Runner {
    return .{ .ctx = ctx, .exec = liveExec };
}

fn liveExec(ctx: *anyopaque, io: std.Io, argv: []const []const u8) !void {
    _ = ctx;
    const allocator = std.heap.page_allocator;
    const result = std.process.run(allocator, io, .{ .argv = argv }) catch return error.CommandFailed;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!result.term.success()) return error.CommandFailed;
}

/// Reloads nginx, the single PHP 8.3 FPM service, node units, postfix, and dovecot.
/// `runner` performs the host commands. Tests pass a recorder. A real Ubuntu root passes `live`.
pub fn apply(db: *Db, io: std.Io, layout: layout_mod.Layout, runner: Runner) !void {
    try activateHttp(db, io, layout, runner);
    try activateMail(db, io, layout, runner);
}

const NodeJob = struct {
    service: [300]u8 = undefined,
    len: usize = 0,
    enable: bool,
};

fn activateHttp(db: *Db, io: std.Io, layout: layout_mod.Layout, runner: Runner) !void {
    _ = layout;
    const query = try db.raw.prepare(
        struct {},
        struct {
            name: sqlite.Text,
            runtime: sqlite.Text,
            public_path: sqlite.Text,
            suspended: i64,
            user_suspended: i64,
            user_name: sqlite.Text,
        },
        "SELECT d.name AS name, d.runtime AS runtime, d.public_path AS public_path, d.suspended AS suspended, COALESCE(f.suspended, 0) AS user_suspended, u.name AS user_name " ++
            "FROM domains d JOIN users u ON u.id = d.user_id LEFT JOIN user_flags f ON f.user_id = u.id",
    );
    defer query.finalize();
    try query.bind(.{});
    defer query.reset();

    var any_http = false;
    var any_php = false;
    var jobs: [32]NodeJob = undefined;
    var job_count: usize = 0;

    while (try query.step()) |row| {
        const active = row.suspended == 0 and row.user_suspended == 0;
        const is_node = std.mem.eql(u8, row.runtime.data, "node");
        const is_php = std.mem.eql(u8, row.runtime.data, "php");
        if (active) {
            any_http = true;
            if (is_php) any_php = true;
            var owner_buf: [80]u8 = undefined;
            const owner = try std.fmt.bufPrint(&owner_buf, "{s}:", .{row.user_name.data});
            var public_buf: [512]u8 = undefined;
            if (row.public_path.data.len > public_buf.len) return error.PathTooLong;
            @memcpy(public_buf[0..row.public_path.data.len], row.public_path.data);
            const public_path = public_buf[0..row.public_path.data.len];
            try runner.exec(runner.ctx, io, &.{ "chown", "-R", owner, public_path });
            try runner.exec(runner.ctx, io, &.{ "chmod", "-R", "a+rX", public_path });
        }
        if (is_node) {
            if (job_count >= jobs.len) return error.TooManyDomains;
            var job = NodeJob{ .enable = active };
            const name = try std.fmt.bufPrint(&job.service, "kalpanel-{s}.service", .{row.name.data});
            job.len = name.len;
            jobs[job_count] = job;
            job_count += 1;
        }
    }

    if (any_php) try runner.exec(runner.ctx, io, &.{ "systemctl", "enable", "--now", "php8.3-fpm" });
    if (any_http) {
        try runner.exec(runner.ctx, io, &.{ "nginx", "-t" });
        try runner.exec(runner.ctx, io, &.{ "systemctl", "enable", "--now", "nginx" });
        try runner.exec(runner.ctx, io, &.{ "systemctl", "reload", "nginx" });
    }
    if (job_count > 0) try runner.exec(runner.ctx, io, &.{ "systemctl", "daemon-reload" });
    for (jobs[0..job_count]) |job| {
        const service = job.service[0..job.len];
        if (job.enable) {
            try runner.exec(runner.ctx, io, &.{ "systemctl", "enable", "--now", service });
        } else {
            runner.exec(runner.ctx, io, &.{ "systemctl", "disable", "--now", service }) catch {};
        }
    }
}

fn activateMail(db: *Db, io: std.Io, layout: layout_mod.Layout, runner: Runner) !void {
    const query = try db.raw.prepare(
        struct {},
        struct { n: i64 },
        "SELECT COUNT(*) AS n FROM emails",
    );
    defer query.finalize();
    try query.bind(.{});
    defer query.reset();
    const row = (try query.step()) orelse return error.Database;
    if (row.n == 0) return;

    var base_buf: [512]u8 = undefined;
    const base = try layout.resolve(&base_buf, "var/mail/kalpanel");
    var domains_buf: [512]u8 = undefined;
    const domains = try layout.resolve(&domains_buf, "etc/postfix/kalpanel-virtual-domains");
    var boxes_buf: [512]u8 = undefined;
    const boxes = try layout.resolve(&boxes_buf, "etc/postfix/kalpanel-virtual-mailboxes");

    runner.exec(runner.ctx, io, &.{ "id", "vmail" }) catch {
        try runner.exec(runner.ctx, io, &.{ "groupadd", "--system", "--gid", "5000", "vmail" });
        try runner.exec(runner.ctx, io, &.{ "useradd", "--system", "--uid", "5000", "--gid", "5000", "--home-dir", base, "--shell", "/usr/sbin/nologin", "vmail" });
    };
    try runner.exec(runner.ctx, io, &.{ "chown", "-R", "vmail:vmail", base });
    try runner.exec(runner.ctx, io, &.{ "postmap", domains });
    try runner.exec(runner.ctx, io, &.{ "postmap", boxes });
    try mergeMaster(io, layout);

    try runner.exec(runner.ctx, io, &.{ "postconf", "-e", "inet_interfaces=all" });
    var domains_arg: [640]u8 = undefined;
    const domains_set = try std.fmt.bufPrint(&domains_arg, "virtual_mailbox_domains=hash:{s}", .{domains});
    try runner.exec(runner.ctx, io, &.{ "postconf", "-e", domains_set });
    var boxes_arg: [640]u8 = undefined;
    const boxes_set = try std.fmt.bufPrint(&boxes_arg, "virtual_mailbox_maps=hash:{s}", .{boxes});
    try runner.exec(runner.ctx, io, &.{ "postconf", "-e", boxes_set });
    var base_arg: [640]u8 = undefined;
    const base_set = try std.fmt.bufPrint(&base_arg, "virtual_mailbox_base={s}", .{base});
    try runner.exec(runner.ctx, io, &.{ "postconf", "-e", base_set });
    try runner.exec(runner.ctx, io, &.{ "postconf", "-e", "virtual_uid_maps=static:5000" });
    try runner.exec(runner.ctx, io, &.{ "postconf", "-e", "virtual_gid_maps=static:5000" });
    var tls_name: [253]u8 = undefined;
    if (try tls_mod.firstDomain(db, &tls_name)) |domain| {
        var full_buf: [512]u8 = undefined;
        var key_buf: [512]u8 = undefined;
        const full = try tls_mod.fullchainPath(layout, &full_buf, domain);
        const key = try tls_mod.privkeyPath(layout, &key_buf, domain);
        var cert_arg: [640]u8 = undefined;
        const cert_set = try std.fmt.bufPrint(&cert_arg, "smtpd_tls_cert_file={s}", .{full});
        try runner.exec(runner.ctx, io, &.{ "postconf", "-e", cert_set });
        var key_arg: [640]u8 = undefined;
        const key_set = try std.fmt.bufPrint(&key_arg, "smtpd_tls_key_file={s}", .{key});
        try runner.exec(runner.ctx, io, &.{ "postconf", "-e", key_set });
    }
    try runner.exec(runner.ctx, io, &.{ "systemctl", "enable", "--now", "postfix" });
    try runner.exec(runner.ctx, io, &.{ "systemctl", "reload", "postfix" });
    try runner.exec(runner.ctx, io, &.{ "systemctl", "enable", "--now", "dovecot" });
    try runner.exec(runner.ctx, io, &.{ "systemctl", "reload", "dovecot" });
}

fn mergeMaster(io: std.Io, layout: layout_mod.Layout) !void {
    var snippet_path_buf: [512]u8 = undefined;
    const snippet_path = try layout.resolve(&snippet_path_buf, "etc/postfix/kalpanel-master.cf");
    var snippet_buf: [2048]u8 = undefined;
    const snippet = layout_mod.readFile(io, snippet_path, &snippet_buf) catch return;

    var master_path_buf: [512]u8 = undefined;
    const master_path = try layout.resolve(&master_path_buf, "etc/postfix/master.cf");
    var existing_buf: [32 * 1024]u8 = undefined;
    const existing = layout_mod.readFile(io, master_path, &existing_buf) catch "";
    if (hasActiveSubmission(existing)) return;

    var out: [36 * 1024]u8 = undefined;
    var len: usize = 0;
    try layout_mod.add(&out, &len, existing);
    if (existing.len > 0 and existing[existing.len - 1] != '\n') try layout_mod.add(&out, &len, "\n");
    try layout_mod.add(&out, &len, snippet);
    try layout_mod.writeFile(io, master_path, out[0..len]);
}

fn hasActiveSubmission(text: []const u8) bool {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "submission inet")) return true;
    }
    return false;
}
