const std = @import("std");
const Db = @import("../database/mod.zig").Db;
const users = @import("../user/mod.zig");
const domain_mod = @import("../domain/mod.zig");
const email_mod = @import("../email/mod.zig");
const setup_mod = @import("../setup/mod.zig");
const layout_mod = @import("../layout.zig");
const ubuntu = @import("../user/ubuntu.zig");
const activate_mod = @import("../activate.zig");
const manager = @import("../dependencies/manager.zig");
const tls_mod = @import("../tls.zig");
const version = @import("../version.zig");

pub const Out = struct {
    buf: []u8,
    len: usize = 0,

    pub fn print(self: *Out, comptime fmt: []const u8, args: anytype) !void {
        const wrote = try std.fmt.bufPrint(self.buf[self.len..], fmt, args);
        self.len += wrote.len;
    }

    pub fn slice(self: *const Out) []const u8 {
        return self.buf[0..self.len];
    }
};

pub fn run(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, out: *Out) !void {
    var apt_ctx: u8 = 0;
    var tls_ctx: u8 = 0;
    return runWith(gpa, io, args, out, setup_mod.live(&apt_ctx), tls_mod.live(&tls_ctx));
}

pub fn runWith(gpa: std.mem.Allocator, io: std.Io, args: []const []const u8, out: *Out, apt: setup_mod.Apt, issuer: tls_mod.Issuer) !void {
    if (args.len < 2) return usage(out);
    var i: usize = 1;
    var db_path: ?[]const u8 = null;
    var root: []const u8 = "";
    while (i < args.len and std.mem.startsWith(u8, args[i], "--")) {
        if (std.mem.eql(u8, args[i], "--db")) {
            if (i + 1 >= args.len) return error.Usage;
            db_path = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--root")) {
            if (i + 1 >= args.len) return error.Usage;
            root = args[i + 1];
            i += 2;
        } else return error.Usage;
    }
    if (i >= args.len) return usage(out);
    const group = args[i];
    if (std.mem.eql(u8, group, "version")) {
        try out.print("kalpanel {s}\n", .{version.string});
        return;
    }
    i += 1;
    const db_path_s = db_path orelse return error.Usage;
    const db_z = try gpa.allocSentinel(u8, db_path_s.len, 0);
    @memcpy(db_z[0..db_path_s.len], db_path_s);
    defer gpa.free(db_z);
    var db = try Db.open(db_z);
    defer db.close();
    const layout = layout_mod.Layout{ .root = root };

    if (std.mem.eql(u8, group, "setup")) {
        const used = try users.featuresInUse(&db);
        try setup_mod.sync(&db, io, used, apt);
        try activateIfReady(&db, io, layout);
        try out.print("setup complete\n", .{});
        return;
    }
    if (std.mem.eql(u8, group, "uninstall")) {
        try setup_mod.uninstall(&db, io, apt);
        try out.print("uninstall complete\n", .{});
        return;
    }
    if (i >= args.len) return error.Usage;
    const action = args[i];
    const rest = args[i + 1 ..];

    if (std.mem.eql(u8, group, "user") and std.mem.eql(u8, action, "create")) {
        return userCreate(&db, io, layout, rest, out);
    }
    if (std.mem.eql(u8, group, "user") and std.mem.eql(u8, action, "list")) {
        const parsed = try parseFlags(rest);
        if (parsed.pos_len != 0) return error.Usage;
        try users.list(&db, out);
        return;
    }
    if (std.mem.eql(u8, group, "user") and std.mem.eql(u8, action, "delete")) {
        const parsed = try parseFlags(rest);
        if (parsed.pos_len != 1) return error.Usage;
        try domain_mod.removeAllForUser(&db, io, layout, parsed.pos[0]);
        if (layout.root.len == 0) {
            try users.remove(&db, io, ubuntu.Host{}, parsed.pos[0]);
        } else {
            try users.remove(&db, io, PrefixHost{ .root = layout.root }, parsed.pos[0]);
        }
        try domain_mod.reload(&db, io, layout);
        try email_mod.reload(&db, io, layout);
        try activateIfReady(&db, io, layout);
        try out.print("deleted user {s}\n", .{parsed.pos[0]});
        return;
    }
    if (std.mem.eql(u8, group, "user") and std.mem.eql(u8, action, "suspend")) {
        const parsed = try parseFlags(rest);
        if (parsed.pos_len != 1) return error.Usage;
        try users.setSuspended(&db, parsed.pos[0], true);
        try domain_mod.reload(&db, io, layout);
        try email_mod.reload(&db, io, layout);
        try activateIfReady(&db, io, layout);
        try out.print("suspended user {s}\n", .{parsed.pos[0]});
        return;
    }
    if (std.mem.eql(u8, group, "domain") and std.mem.eql(u8, action, "create")) {
        const parsed = try parseFlags(rest);
        if (parsed.pos_len != 2) return error.Usage;
        const runtime = domain_mod.parseRuntime(parsed.runtime orelse return error.Usage) orelse return error.Usage;
        try domain_mod.create(&db, io, layout, parsed.pos[0], parsed.pos[1], runtime);
        try activateIfReady(&db, io, layout);
        try out.print("created domain {s} runtime {s}\n", .{ parsed.pos[1], @tagName(runtime) });
        return;
    }
    if (std.mem.eql(u8, group, "domain") and std.mem.eql(u8, action, "list")) {
        const parsed = try parseFlags(rest);
        if (parsed.pos_len > 1) return error.Usage;
        const owner = if (parsed.pos_len == 1) parsed.pos[0] else null;
        try domain_mod.list(&db, owner, out);
        return;
    }
    if (std.mem.eql(u8, group, "domain") and std.mem.eql(u8, action, "delete")) {
        const parsed = try parseFlags(rest);
        if (parsed.pos_len != 1) return error.Usage;
        try domain_mod.remove(&db, io, layout, parsed.pos[0]);
        try email_mod.reload(&db, io, layout);
        try activateIfReady(&db, io, layout);
        try out.print("deleted domain {s}\n", .{parsed.pos[0]});
        return;
    }
    if (std.mem.eql(u8, group, "domain") and std.mem.eql(u8, action, "suspend")) {
        const parsed = try parseFlags(rest);
        if (parsed.pos_len != 1) return error.Usage;
        try domain_mod.suspendName(&db, io, layout, parsed.pos[0]);
        try email_mod.reload(&db, io, layout);
        try activateIfReady(&db, io, layout);
        try out.print("suspended domain {s}\n", .{parsed.pos[0]});
        return;
    }
    if (std.mem.eql(u8, group, "domain") and std.mem.eql(u8, action, "tls")) {
        const parsed = try parseFlags(rest);
        if (parsed.pos_len != 2) return error.Usage;
        try domain_mod.enableTls(&db, io, layout, parsed.pos[0], parsed.pos[1], issuer);
        try email_mod.reload(&db, io, layout);
        try activateIfReady(&db, io, layout);
        try out.print("enabled tls {s}\nhttps://{s}\n", .{ parsed.pos[0], parsed.pos[0] });
        return;
    }
    if (std.mem.eql(u8, group, "domain") and std.mem.eql(u8, action, "renew")) {
        try domain_mod.renewCerts(&db, io, layout, issuer);
        try email_mod.reload(&db, io, layout);
        try activateIfReady(&db, io, layout);
        try out.print("renewed certificates\n", .{});
        return;
    }
    if (std.mem.eql(u8, group, "email") and std.mem.eql(u8, action, "create")) {
        const parsed = try parseFlags(rest);
        if (parsed.pos_len != 1) return error.Usage;
        var password_buf: [32]u8 = undefined;
        const password = try email_mod.create(&db, io, layout, parsed.pos[0], &password_buf);
        try activateIfReady(&db, io, layout);
        try out.print("created email {s}\npassword: {s}\n", .{ parsed.pos[0], password });
        return;
    }
    if (std.mem.eql(u8, group, "email") and std.mem.eql(u8, action, "list")) {
        const parsed = try parseFlags(rest);
        if (parsed.pos_len != 1) return error.Usage;
        try email_mod.list(&db, parsed.pos[0], out);
        return;
    }
    if (std.mem.eql(u8, group, "email") and std.mem.eql(u8, action, "delete")) {
        const parsed = try parseFlags(rest);
        if (parsed.pos_len != 1) return error.Usage;
        try email_mod.remove(&db, io, layout, parsed.pos[0]);
        try activateIfReady(&db, io, layout);
        try out.print("deleted email {s}\n", .{parsed.pos[0]});
        return;
    }
    if (std.mem.eql(u8, group, "email") and std.mem.eql(u8, action, "suspend")) {
        const parsed = try parseFlags(rest);
        if (parsed.pos_len != 1) return error.Usage;
        try email_mod.suspendName(&db, io, layout, parsed.pos[0]);
        try activateIfReady(&db, io, layout);
        try out.print("suspended email {s}\n", .{parsed.pos[0]});
        return;
    }
    return error.Usage;
}

fn userCreate(db: *Db, io: std.Io, layout: layout_mod.Layout, rest: []const []const u8, out: *Out) !void {
    const parsed = try parseFlags(rest);
    if (parsed.pos_len != 1) return error.Usage;
    const role = users.parseRole(parsed.role orelse return error.Usage) orelse return error.Usage;
    var actor: ?users.Actor = null;
    if (parsed.actor) |name| {
        var home_buf: [512]u8 = undefined;
        const account = (try users.lookup(db, name, &home_buf)) orelse return error.UserNotFound;
        if (account.suspended) return error.UserSuspended;
        actor = switch (account.role) {
            .admin => .admin,
            .reseller => .reseller,
            .user => return error.Forbidden,
        };
    }
    const req = users.Request{
        .name = parsed.pos[0],
        .role = role,
        .actor = actor,
        .features = .{
            .domain = parsed.domain,
            .email = parsed.email,
            .php = parsed.php,
            .node = parsed.node,
        },
    };
    var home_buf: [512]u8 = undefined;
    if (layout.root.len == 0) {
        _ = try users.create(db, io, ubuntu.Host{}, req, &home_buf);
    } else {
        _ = try users.create(db, io, PrefixHost{ .root = layout.root }, req, &home_buf);
    }
    try out.print("created user {s}\n", .{parsed.pos[0]});
}

const PrefixHost = struct {
    root: []const u8,

    pub fn home(self: PrefixHost, io: std.Io, name: []const u8, buf: []u8) ![]const u8 {
        const path = try std.fmt.bufPrint(buf, "{s}/home/{s}", .{ self.root, name });
        try std.Io.Dir.cwd().createDirPath(io, path);
        return path;
    }

    pub fn rollback(self: PrefixHost, io: std.Io, name: []const u8) void {
        var buf: [512]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/home/{s}", .{ self.root, name }) catch return;
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
    }
};

const Parsed = struct {
    pos: [4][]const u8 = undefined,
    pos_len: usize = 0,
    role: ?[]const u8 = null,
    actor: ?[]const u8 = null,
    runtime: ?[]const u8 = null,
    domain: bool = false,
    email: bool = false,
    php: bool = false,
    node: bool = false,
};

fn parseFlags(args: []const []const u8) !Parsed {
    var parsed = Parsed{};
    var i: usize = 0;
    while (i < args.len) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--role")) {
            if (i + 1 >= args.len) return error.Usage;
            parsed.role = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, arg, "--actor")) {
            if (i + 1 >= args.len) return error.Usage;
            parsed.actor = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, arg, "--runtime")) {
            if (i + 1 >= args.len) return error.Usage;
            parsed.runtime = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, arg, "--domain")) {
            parsed.domain = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--email")) {
            parsed.email = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--php")) {
            parsed.php = true;
            i += 1;
        } else if (std.mem.eql(u8, arg, "--node")) {
            parsed.node = true;
            i += 1;
        } else if (std.mem.startsWith(u8, arg, "--")) {
            return error.Usage;
        } else {
            if (parsed.pos_len >= parsed.pos.len) return error.Usage;
            parsed.pos[parsed.pos_len] = arg;
            parsed.pos_len += 1;
            i += 1;
        }
    }
    return parsed;
}

fn activateIfReady(db: *Db, io: std.Io, layout: layout_mod.Layout) !void {
    if (!layout.system()) return;
    const used = try users.featuresInUse(db);
    if (!manager.ready(used)) return;
    var dummy: u8 = 0;
    try activate_mod.apply(db, io, layout, activate_mod.live(&dummy));
}

fn usage(out: *Out) !void {
    try out.print(
        \\kalpanel {s}
        \\kalpanel version
        \\kalpanel --db PATH [--root PATH] <command>
        \\  user create NAME --role admin|reseller|user [--actor NAME] [--domain] [--email] [--php] [--node]
        \\  user list
        \\  user suspend NAME
        \\  user delete NAME
        \\  domain create USER DOMAIN --runtime php|node
        \\  domain list [USER]
        \\  domain suspend DOMAIN
        \\  domain delete DOMAIN
        \\  domain tls DOMAIN EMAIL
        \\  domain renew
        \\  email create LOCAL@DOMAIN
        \\  email list DOMAIN
        \\  email suspend LOCAL@DOMAIN
        \\  email delete LOCAL@DOMAIN
        \\  setup
        \\  uninstall
        \\
    , .{version.string});
    return error.Usage;
}
