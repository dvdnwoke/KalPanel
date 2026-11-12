const std = @import("std");
const cli = @import("mod.zig");
const email_mod = @import("../email/mod.zig");
const layout_mod = @import("../layout.zig");
const setup_mod = @import("../setup/mod.zig");
const tls_mod = @import("../tls.zig");
const version = @import("../version.zig");
const activate_mod = @import("../activate.zig");
const Db = @import("../database/mod.zig").Db;
const FeatureSet = @import("../dependencies/features.zig").FeatureSet;

const Fake = struct {
    present: []const []const u8,
    installed: [8][]const u8 = undefined,
    installed_len: usize = 0,
    installed_store: [512]u8 = undefined,
    installed_used: usize = 0,
    removed: [8][]const u8 = undefined,
    removed_len: usize = 0,
    removed_store: [512]u8 = undefined,
    removed_used: usize = 0,

    fn apt(self: *Fake) setup_mod.Apt {
        return .{
            .ctx = self,
            .isInstalled = isInstalled,
            .install = install,
            .remove = remove,
        };
    }

    fn isInstalled(ctx: *anyopaque, io: std.Io, name: []const u8) bool {
        _ = io;
        const self: *Fake = @ptrCast(@alignCast(ctx));
        for (self.present) |item| if (std.mem.eql(u8, item, name)) return true;
        for (self.installed[0..self.installed_len]) |item| if (std.mem.eql(u8, item, name)) return true;
        return false;
    }

    fn install(ctx: *anyopaque, io: std.Io, names: []const []const u8) !void {
        _ = io;
        const self: *Fake = @ptrCast(@alignCast(ctx));
        for (names) |name| try self.keep(&self.installed, &self.installed_len, &self.installed_store, &self.installed_used, name);
    }

    fn remove(ctx: *anyopaque, io: std.Io, names: []const []const u8) !void {
        _ = io;
        const self: *Fake = @ptrCast(@alignCast(ctx));
        for (names) |name| try self.keep(&self.removed, &self.removed_len, &self.removed_store, &self.removed_used, name);
    }

    fn keep(self: *Fake, list: *[8][]const u8, len: *usize, store: *[512]u8, used: *usize, name: []const u8) !void {
        _ = self;
        if (len.* >= list.len) return error.TooManyPackages;
        if (used.* + name.len > store.len) return error.TooManyPackages;
        const dest = store[used.*..][0..name.len];
        @memcpy(dest, name);
        list[len.*] = dest;
        used.* += name.len;
        len.* += 1;
    }
};

const FakeIssuer = struct {
    domain: [253]u8 = undefined,
    domain_len: usize = 0,
    webroot: [512]u8 = undefined,
    webroot_len: usize = 0,
    email: [128]u8 = undefined,
    email_len: usize = 0,
    renewed: bool = false,

    fn issuer(self: *FakeIssuer) tls_mod.Issuer {
        return .{ .ctx = self, .issue = issue, .renew = renew };
    }

    fn issue(ctx: *anyopaque, io: std.Io, domain: []const u8, webroot: []const u8, email: []const u8, config_dir: []const u8) !void {
        const self: *FakeIssuer = @ptrCast(@alignCast(ctx));
        if (domain.len > self.domain.len or webroot.len > self.webroot.len or email.len > self.email.len) return error.TooLong;
        @memcpy(self.domain[0..domain.len], domain);
        self.domain_len = domain.len;
        @memcpy(self.webroot[0..webroot.len], webroot);
        self.webroot_len = webroot.len;
        @memcpy(self.email[0..email.len], email);
        self.email_len = email.len;

        var full_buf: [768]u8 = undefined;
        const full = try std.fmt.bufPrint(&full_buf, "{s}/live/{s}/fullchain.pem", .{ config_dir, domain });
        try layout_mod.writeFile(io, full, "kalpanel-test-cert\n");
        var key_buf: [768]u8 = undefined;
        const key = try std.fmt.bufPrint(&key_buf, "{s}/live/{s}/privkey.pem", .{ config_dir, domain });
        try layout_mod.writeFile(io, key, "kalpanel-test-key\n");
    }

    fn renew(ctx: *anyopaque, io: std.Io, config_dir: []const u8) !void {
        _ = io;
        _ = config_dir;
        const self: *FakeIssuer = @ptrCast(@alignCast(ctx));
        self.renewed = true;
    }
};

fn exec(io: std.Io, root: []const u8, db_path: []const u8, args: []const []const u8, apt: ?setup_mod.Apt, issuer: ?tls_mod.Issuer, out_buf: []u8) ![]const u8 {
    var out = cli.Out{ .buf = out_buf };
    var argv: [16][]const u8 = undefined;
    argv[0] = "kalpanel";
    argv[1] = "--db";
    argv[2] = db_path;
    argv[3] = "--root";
    argv[4] = root;
    for (args, 0..) |arg, i| argv[5 + i] = arg;
    if (apt == null and issuer == null) {
        try cli.run(std.testing.allocator, io, argv[0 .. 5 + args.len], &out);
    } else {
        var apt_ctx: u8 = 0;
        var tls_ctx: u8 = 0;
        const apt_real = apt orelse setup_mod.live(&apt_ctx);
        const issuer_real = issuer orelse tls_mod.live(&tls_ctx);
        try cli.runWith(std.testing.allocator, io, argv[0 .. 5 + args.len], &out, apt_real, issuer_real);
    }
    return out.slice();
}

test "sha256 password scheme is dovecot base64" {
    var buf: [64]u8 = undefined;
    const hash = email_mod.sha256B64("", &buf);
    try std.testing.expectEqualStrings("47DEQpj8HBSa+/TImW+5JCeuQeRkm5NMpJWZG3hSuFU=", hash);
}

test "cli hosts php and node on port 80 and mail for outlook" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "/tmp/kalpanel-cli-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const db_path = root ++ "/kalpanel.sqlite";

    var out_buf: [512]u8 = undefined;
    _ = try exec(io, root, db_path, &.{ "user", "create", "admin", "--role", "admin", "--domain", "--email", "--php", "--node" }, null, null, &out_buf);

    _ = try exec(io, root, db_path, &.{ "domain", "create", "admin", "example.com", "--runtime", "php" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "domain", "create", "admin", "app.example.com", "--runtime", "node" }, null, null, &out_buf);
    const email_out = try exec(io, root, db_path, &.{ "email", "create", "alice@example.com" }, null, null, &out_buf);
    const password_view = passwordOf(email_out);
    try std.testing.expect(password_view.len == 18);
    var password_store: [32]u8 = undefined;
    @memcpy(password_store[0..password_view.len], password_view);
    const password = password_store[0..password_view.len];

    var buf: [4096]u8 = undefined;
    const php_conf = try layout_mod.readFile(io, root ++ "/etc/nginx/sites-enabled/example.com.conf", &buf);
    try std.testing.expect(std.mem.indexOf(u8, php_conf, "listen 80;") != null);
    try std.testing.expect(std.mem.indexOf(u8, php_conf, "listen [::]:80;") != null);
    try std.testing.expect(std.mem.indexOf(u8, php_conf, "server_name example.com;") != null);
    try std.testing.expect(std.mem.indexOf(u8, php_conf, "unix:/run/php/php8.3-fpm.sock") != null);
    try std.testing.expect(std.mem.indexOf(u8, php_conf, "php8.2") == null);
    try std.testing.expect(std.mem.indexOf(u8, php_conf, "php8.4") == null);
    try std.testing.expect(std.mem.indexOf(u8, php_conf, "/home/admin/domains/example.com/public") != null);

    var php_buf: [128]u8 = undefined;
    const php_src = try layout_mod.readFile(io, root ++ "/home/admin/domains/example.com/public/index.php", &php_buf);
    try std.testing.expect(std.mem.indexOf(u8, php_src, "kalpanel-php-ok") != null);

    var node_buf: [2048]u8 = undefined;
    const node_conf = try layout_mod.readFile(io, root ++ "/etc/nginx/sites-enabled/app.example.com.conf", &node_buf);
    try std.testing.expect(std.mem.indexOf(u8, node_conf, "listen 80;") != null);
    try std.testing.expect(std.mem.indexOf(u8, node_conf, "proxy_pass http://127.0.0.1:20000;") != null);

    var unit_buf: [1024]u8 = undefined;
    const unit = try layout_mod.readFile(io, root ++ "/etc/systemd/system/kalpanel-app.example.com.service", &unit_buf);
    try std.testing.expect(std.mem.indexOf(u8, unit, "ExecStart=/usr/bin/node ") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "Environment=PORT=20000") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "server.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, unit, "nvm") == null);

    var js_buf: [512]u8 = undefined;
    const js = try layout_mod.readFile(io, root ++ "/home/admin/domains/app.example.com/public/server.js", &js_buf);
    try std.testing.expect(std.mem.indexOf(u8, js, "127.0.0.1") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "kalpanel-node-ok") != null);

    var mail_buf: [4096]u8 = undefined;
    const cf = try layout_mod.readFile(io, root ++ "/etc/postfix/kalpanel.cf", &mail_buf);
    try std.testing.expect(std.mem.indexOf(u8, cf, "inet_interfaces = all") != null);
    try std.testing.expect(std.mem.indexOf(u8, cf, "virtual_mailbox_domains = hash:") != null);

    var box_buf: [1024]u8 = undefined;
    const boxes = try layout_mod.readFile(io, root ++ "/etc/postfix/kalpanel-virtual-mailboxes", &box_buf);
    try std.testing.expect(std.mem.indexOf(u8, boxes, "alice@example.com example.com/alice/") != null);

    var domains_buf: [256]u8 = undefined;
    const domains = try layout_mod.readFile(io, root ++ "/etc/postfix/kalpanel-virtual-domains", &domains_buf);
    try std.testing.expect(std.mem.indexOf(u8, domains, "example.com\n") != null);

    var master_buf: [1024]u8 = undefined;
    const master = try layout_mod.readFile(io, root ++ "/etc/postfix/kalpanel-master.cf", &master_buf);
    try std.testing.expect(std.mem.indexOf(u8, master, "submission inet") != null);
    try std.testing.expect(std.mem.indexOf(u8, master, "smtpd_sasl_auth_enable=yes") != null);

    var dove_buf: [2048]u8 = undefined;
    const dove = try layout_mod.readFile(io, root ++ "/etc/dovecot/conf.d/99-kalpanel.conf", &dove_buf);
    try std.testing.expect(std.mem.indexOf(u8, dove, "port = 993") != null);
    try std.testing.expect(std.mem.indexOf(u8, dove, "protocols = imap") != null);

    var hash_buf: [64]u8 = undefined;
    const hash = email_mod.sha256B64(password, &hash_buf);
    var pass_buf: [512]u8 = undefined;
    const passwd = try layout_mod.readFile(io, root ++ "/etc/dovecot/kalpanel.passwd", &pass_buf);
    try std.testing.expect(std.mem.indexOf(u8, passwd, "alice@example.com:{SHA256}") != null);
    try std.testing.expect(std.mem.indexOf(u8, passwd, hash) != null);

    _ = try exec(io, root, db_path, &.{ "email", "suspend", "alice@example.com" }, null, null, &out_buf);
    const passwd_after = try layout_mod.readFile(io, root ++ "/etc/dovecot/kalpanel.passwd", &pass_buf);
    try std.testing.expect(std.mem.indexOf(u8, passwd_after, "alice@example.com") == null);
    const boxes_after = try layout_mod.readFile(io, root ++ "/etc/postfix/kalpanel-virtual-mailboxes", &box_buf);
    try std.testing.expect(std.mem.indexOf(u8, boxes_after, "alice@example.com") == null);

    _ = try exec(io, root, db_path, &.{ "domain", "suspend", "example.com" }, null, null, &out_buf);
    try std.testing.expectError(error.FileNotFound, layout_mod.readFile(io, root ++ "/etc/nginx/sites-enabled/example.com.conf", &buf));
    _ = try layout_mod.readFile(io, root ++ "/etc/nginx/sites-enabled/app.example.com.conf", &node_buf);

    _ = try exec(io, root, db_path, &.{ "user", "suspend", "admin" }, null, null, &out_buf);
    try std.testing.expectError(error.FileNotFound, layout_mod.readFile(io, root ++ "/etc/nginx/sites-enabled/app.example.com.conf", &node_buf));
    try std.testing.expectError(error.FileNotFound, layout_mod.readFile(io, root ++ "/etc/systemd/system/kalpanel-app.example.com.service", &unit_buf));
}

fn passwordOf(text: []const u8) []const u8 {
    const marker = "password: ";
    const at = std.mem.indexOf(u8, text, marker).?;
    const rest = text[at + marker.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
    return rest[0..end];
}

test "setup records only packages it installed" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "/tmp/kalpanel-setup-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const db_path = root ++ "/kalpanel.sqlite";

    var out_buf: [256]u8 = undefined;
    var fake = Fake{ .present = &.{ "nginx", "postfix" } };
    _ = try exec(io, root, db_path, &.{ "user", "create", "admin", "--role", "admin", "--domain", "--php", "--email" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "setup" }, fake.apt(), null, &out_buf);

    try std.testing.expectEqual(@as(usize, 4), fake.installed_len);
    try std.testing.expect(contains(&fake.installed, fake.installed_len, "certbot"));
    try std.testing.expect(contains(&fake.installed, fake.installed_len, "php8.3-cli"));
    try std.testing.expect(contains(&fake.installed, fake.installed_len, "php8.3-fpm"));
    try std.testing.expect(contains(&fake.installed, fake.installed_len, "dovecot-imapd"));
    try std.testing.expect(!contains(&fake.installed, fake.installed_len, "nginx"));
    try std.testing.expect(!contains(&fake.installed, fake.installed_len, "postfix"));
    try std.testing.expect(!contains(&fake.installed, fake.installed_len, "nodejs"));
    try std.testing.expect(!contains(&fake.installed, fake.installed_len, "php8.2-fpm"));

    _ = try exec(io, root, db_path, &.{ "setup" }, fake.apt(), null, &out_buf);
    try std.testing.expectEqual(@as(usize, 4), fake.installed_len);

    _ = try exec(io, root, db_path, &.{ "uninstall" }, fake.apt(), null, &out_buf);
    try std.testing.expectEqual(@as(usize, 4), fake.removed_len);
    try std.testing.expect(contains(&fake.removed, fake.removed_len, "certbot"));
    try std.testing.expect(contains(&fake.removed, fake.removed_len, "php8.3-cli"));
    try std.testing.expect(contains(&fake.removed, fake.removed_len, "php8.3-fpm"));
    try std.testing.expect(contains(&fake.removed, fake.removed_len, "dovecot-imapd"));
    try std.testing.expect(!contains(&fake.removed, fake.removed_len, "nginx"));
    try std.testing.expect(!contains(&fake.removed, fake.removed_len, "postfix"));

    _ = FeatureSet{};
}

fn contains(items: []const []const u8, n: usize, name: []const u8) bool {
    for (items[0..n]) |item| if (std.mem.eql(u8, item, name)) return true;
    return false;
}

const Rec = struct {
    log: [8192]u8 = undefined,
    len: usize = 0,

    fn runner(self: *Rec) activate_mod.Runner {
        return .{ .ctx = self, .exec = execCmd };
    }

    fn execCmd(ctx: *anyopaque, io: std.Io, argv: []const []const u8) !void {
        _ = io;
        const self: *Rec = @ptrCast(@alignCast(ctx));
        if (argv.len > 0 and std.mem.eql(u8, argv[0], "id")) return error.CommandFailed;
        for (argv) |arg| {
            if (self.len + arg.len + 1 > self.log.len) return error.LogFull;
            @memcpy(self.log[self.len..][0..arg.len], arg);
            self.len += arg.len;
            self.log[self.len] = ' ';
            self.len += 1;
        }
        if (self.len + 1 > self.log.len) return error.LogFull;
        self.log[self.len] = '\n';
        self.len += 1;
    }

    fn text(self: *const Rec) []const u8 {
        return self.log[0..self.len];
    }
};

test "activation reloads php 8.3, node, nginx, and outlook mail" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "/tmp/kalpanel-activate-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const db_path = root ++ "/kalpanel.sqlite";
    var out_buf: [512]u8 = undefined;
    _ = try exec(io, root, db_path, &.{ "user", "create", "admin", "--role", "admin", "--domain", "--email", "--php", "--node" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "domain", "create", "admin", "example.com", "--runtime", "php" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "domain", "create", "admin", "app.example.com", "--runtime", "node" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "email", "create", "alice@example.com" }, null, null, &out_buf);

    const db_z = try std.testing.allocator.allocSentinel(u8, db_path.len, 0);
    defer std.testing.allocator.free(db_z);
    @memcpy(db_z[0..db_path.len], db_path);
    var db = try Db.open(db_z);
    defer db.close();

    var rec = Rec{};
    try activate_mod.apply(&db, io, .{ .root = root }, rec.runner());
    const log = rec.text();
    try std.testing.expect(std.mem.indexOf(u8, log, "systemctl enable --now php8.3-fpm") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "nginx -t") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "systemctl reload nginx") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "systemctl enable --now kalpanel-app.example.com.service") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "/usr/bin/node") == null);
    try std.testing.expect(std.mem.indexOf(u8, log, "useradd --system --uid 5000 --gid 5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "postmap ") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "postconf -e inet_interfaces=all") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "virtual_uid_maps=static:5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "systemctl reload dovecot") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "systemctl reload postfix") != null);

    var master_buf: [4096]u8 = undefined;
    const master = try layout_mod.readFile(io, root ++ "/etc/postfix/master.cf", &master_buf);
    try std.testing.expect(std.mem.indexOf(u8, master, "submission inet") != null);
    try std.testing.expect(std.mem.indexOf(u8, master, "smtpd_sasl_auth_enable=yes") != null);
}

test "version is 0.0.6" {
    try std.testing.expectEqualStrings("0.0.6", version.string);
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    var buf: [64]u8 = undefined;
    var out = cli.Out{ .buf = &buf };
    try cli.run(std.testing.allocator, threaded.io(), &.{ "kalpanel", "version" }, &out);
    try std.testing.expectEqualStrings("kalpanel 0.0.6\n", out.slice());
}

test "lets encrypt serves the site on port 443" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "/tmp/kalpanel-tls-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const db_path = root ++ "/kalpanel.sqlite";

    var out_buf: [512]u8 = undefined;
    var issuer = FakeIssuer{};
    _ = try exec(io, root, db_path, &.{ "user", "create", "admin", "--role", "admin", "--domain", "--email", "--php", "--node" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "domain", "create", "admin", "example.com", "--runtime", "php" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "domain", "create", "admin", "app.example.com", "--runtime", "node" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "email", "create", "alice@example.com" }, null, null, &out_buf);

    var conf_buf: [4096]u8 = undefined;
    const before = try layout_mod.readFile(io, root ++ "/etc/nginx/sites-enabled/example.com.conf", &conf_buf);
    try std.testing.expect(std.mem.indexOf(u8, before, "listen 80;") != null);
    try std.testing.expect(std.mem.indexOf(u8, before, "/.well-known/acme-challenge/") != null);
    try std.testing.expect(std.mem.indexOf(u8, before, "listen 443 ssl;") == null);

    const tls_out = try exec(io, root, db_path, &.{ "domain", "tls", "example.com", "admin@example.com" }, null, issuer.issuer(), &out_buf);
    try std.testing.expect(std.mem.indexOf(u8, tls_out, "https://example.com") != null);
    try std.testing.expectEqualStrings("example.com", issuer.domain[0..issuer.domain_len]);
    try std.testing.expectEqualStrings("admin@example.com", issuer.email[0..issuer.email_len]);
    try std.testing.expect(std.mem.indexOf(u8, issuer.webroot[0..issuer.webroot_len], "/home/admin/domains/example.com/public") != null);

    const after = try layout_mod.readFile(io, root ++ "/etc/nginx/sites-enabled/example.com.conf", &conf_buf);
    try std.testing.expect(std.mem.indexOf(u8, after, "listen 80;") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "listen [::]:80;") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "listen 443 ssl;") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "listen [::]:443 ssl;") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "return 301 https://$host$request_uri;") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "ssl_certificate ") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "/etc/letsencrypt/live/example.com/fullchain.pem;") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "/etc/letsencrypt/live/example.com/privkey.pem;") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "unix:/run/php/php8.3-fpm.sock") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "fastcgi_param HTTPS on;") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "php8.2") == null);

    var node_buf: [2048]u8 = undefined;
    const node_conf = try layout_mod.readFile(io, root ++ "/etc/nginx/sites-enabled/app.example.com.conf", &node_buf);
    try std.testing.expect(std.mem.indexOf(u8, node_conf, "ssl_certificate ") == null);
    try std.testing.expect(std.mem.indexOf(u8, node_conf, "proxy_pass http://127.0.0.1:20000;") != null);

    var cert_buf: [64]u8 = undefined;
    const cert = try layout_mod.readFile(io, root ++ "/etc/letsencrypt/live/example.com/fullchain.pem", &cert_buf);
    try std.testing.expectEqualStrings("kalpanel-test-cert\n", cert);

    var dove_buf: [2048]u8 = undefined;
    const dove = try layout_mod.readFile(io, root ++ "/etc/dovecot/conf.d/99-kalpanel.conf", &dove_buf);
    try std.testing.expect(std.mem.indexOf(u8, dove, "fullchain.pem") != null);
    try std.testing.expect(std.mem.indexOf(u8, dove, "ssl-cert-snakeoil") == null);
    try std.testing.expect(std.mem.indexOf(u8, dove, "port = 993") != null);

    var hook_buf: [256]u8 = undefined;
    const hook = try layout_mod.readFile(io, root ++ "/etc/letsencrypt/renewal-hooks/deploy/kalpanel", &hook_buf);
    try std.testing.expect(std.mem.indexOf(u8, hook, "nginx -s reload") != null);

    _ = try exec(io, root, db_path, &.{ "domain", "renew" }, null, issuer.issuer(), &out_buf);
    try std.testing.expect(issuer.renewed);
    const still = try layout_mod.readFile(io, root ++ "/etc/nginx/sites-enabled/example.com.conf", &conf_buf);
    try std.testing.expect(std.mem.indexOf(u8, still, "listen 443 ssl;") != null);
}

test "rejects unsafe names, missing features, and duplicate domains" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "/tmp/kalpanel-reject-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const db_path = root ++ "/kalpanel.sqlite";
    var out_buf: [512]u8 = undefined;

    _ = try exec(io, root, db_path, &.{ "user", "create", "admin", "--role", "admin", "--domain", "--php", "--email" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "domain", "create", "admin", "example.com", "--runtime", "php" }, null, null, &out_buf);

    const bad_domains = [_][]const u8{ "Example.COM", "-bad.com", "bad-.com", "a..b.com", "../etc" };
    for (bad_domains) |name| {
        try std.testing.expectError(error.InvalidDomain, exec(io, root, db_path, &.{ "domain", "create", "admin", name, "--runtime", "php" }, null, null, &out_buf));
    }
    try std.testing.expectError(error.DomainExists, exec(io, root, db_path, &.{ "domain", "create", "admin", "example.com", "--runtime", "php" }, null, null, &out_buf));
    try std.testing.expectError(error.InvalidAddress, exec(io, root, db_path, &.{ "email", "create", "..@example.com" }, null, null, &out_buf));
    try std.testing.expectError(error.InvalidAddress, exec(io, root, db_path, &.{ "email", "create", "a..b@example.com" }, null, null, &out_buf));

    _ = try exec(io, root, db_path, &.{ "user", "create", "plain", "--role", "user", "--actor", "admin", "--domain" }, null, null, &out_buf);
    try std.testing.expectError(error.FeatureNotEnabled, exec(io, root, db_path, &.{ "domain", "create", "plain", "plain.example", "--runtime", "php" }, null, null, &out_buf));
    try std.testing.expectError(error.FeatureNotEnabled, exec(io, root, db_path, &.{ "domain", "create", "plain", "plain.example", "--runtime", "node" }, null, null, &out_buf));

    _ = try exec(io, root, db_path, &.{ "user", "create", "nodes", "--role", "user", "--actor", "admin", "--domain", "--node" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "domain", "create", "nodes", "one.example", "--runtime", "node" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "domain", "create", "nodes", "two.example", "--runtime", "node" }, null, null, &out_buf);
    var unit_buf: [1024]u8 = undefined;
    const first = try layout_mod.readFile(io, root ++ "/etc/systemd/system/kalpanel-one.example.service", &unit_buf);
    try std.testing.expect(std.mem.indexOf(u8, first, "Environment=PORT=20000") != null);
    const second = try layout_mod.readFile(io, root ++ "/etc/systemd/system/kalpanel-two.example.service", &unit_buf);
    try std.testing.expect(std.mem.indexOf(u8, second, "Environment=PORT=20001") != null);

    _ = try exec(io, root, db_path, &.{ "user", "suspend", "admin" }, null, null, &out_buf);
    try std.testing.expectError(error.UserSuspended, exec(io, root, db_path, &.{ "user", "create", "later", "--role", "user", "--actor", "admin" }, null, null, &out_buf));
}

test "list and delete keep the other user domain and mailbox" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const root = "/tmp/kalpanel-list-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};
    const db_path = root ++ "/kalpanel.sqlite";
    var out_buf: [4096]u8 = undefined;

    _ = try exec(io, root, db_path, &.{ "user", "create", "admin", "--role", "admin", "--domain", "--email", "--php" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "user", "create", "bob", "--role", "user", "--actor", "admin", "--domain", "--email", "--node" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "domain", "create", "admin", "example.com", "--runtime", "php" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "domain", "create", "bob", "other.com", "--runtime", "node" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "email", "create", "a@example.com" }, null, null, &out_buf);
    _ = try exec(io, root, db_path, &.{ "email", "create", "c@other.com" }, null, null, &out_buf);

    const users_out = try exec(io, root, db_path, &.{ "user", "list" }, null, null, &out_buf);
    try std.testing.expect(std.mem.indexOf(u8, users_out, "user admin role admin suspended 0 features domain,email,php\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, users_out, "user bob role user suspended 0 features domain,email,node\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, users_out, "password") == null);

    const admin_domains = try exec(io, root, db_path, &.{ "domain", "list", "admin" }, null, null, &out_buf);
    try std.testing.expect(std.mem.indexOf(u8, admin_domains, "domain example.com user admin runtime php port 0 suspended 0 tls 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, admin_domains, "other.com") == null);

    const all_domains = try exec(io, root, db_path, &.{ "domain", "list" }, null, null, &out_buf);
    try std.testing.expect(std.mem.indexOf(u8, all_domains, "example.com") != null);
    try std.testing.expect(std.mem.indexOf(u8, all_domains, "domain other.com user bob runtime node port 20000 ") != null);

    const example_mail = try exec(io, root, db_path, &.{ "email", "list", "example.com" }, null, null, &out_buf);
    try std.testing.expect(std.mem.indexOf(u8, example_mail, "email a@example.com suspended 0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, example_mail, "c@other.com") == null);

    _ = try exec(io, root, db_path, &.{ "email", "delete", "a@example.com" }, null, null, &out_buf);
    const after_mail = try exec(io, root, db_path, &.{ "email", "list", "example.com" }, null, null, &out_buf);
    try std.testing.expectEqualStrings("no emails\n", after_mail);
    var pass_buf: [512]u8 = undefined;
    const passwd = try layout_mod.readFile(io, root ++ "/etc/dovecot/kalpanel.passwd", &pass_buf);
    try std.testing.expect(std.mem.indexOf(u8, passwd, "a@example.com") == null);
    try std.testing.expect(std.mem.indexOf(u8, passwd, "c@other.com") != null);
    try std.testing.expectError(error.EmailNotFound, exec(io, root, db_path, &.{ "email", "delete", "a@example.com" }, null, null, &out_buf));

    _ = try exec(io, root, db_path, &.{ "domain", "delete", "example.com" }, null, null, &out_buf);
    try std.testing.expectError(error.FileNotFound, layout_mod.readFile(io, root ++ "/etc/nginx/sites-enabled/example.com.conf", &out_buf));
    try std.testing.expectError(error.FileNotFound, layout_mod.readFile(io, root ++ "/etc/nginx/sites-available/example.com.conf", &out_buf));
    try std.testing.expectError(error.FileNotFound, layout_mod.readFile(io, root ++ "/home/admin/domains/example.com/public/index.php", &out_buf));
    try std.testing.expectError(error.DomainNotFound, exec(io, root, db_path, &.{ "email", "list", "example.com" }, null, null, &out_buf));
    _ = try layout_mod.readFile(io, root ++ "/etc/nginx/sites-enabled/other.com.conf", &out_buf);
    _ = try layout_mod.readFile(io, root ++ "/etc/systemd/system/kalpanel-other.com.service", &out_buf);

    _ = try exec(io, root, db_path, &.{ "user", "delete", "bob" }, null, null, &out_buf);
    const left = try exec(io, root, db_path, &.{ "user", "list" }, null, null, &out_buf);
    try std.testing.expect(std.mem.indexOf(u8, left, "user admin ") != null);
    try std.testing.expect(std.mem.indexOf(u8, left, "user bob ") == null);
    try std.testing.expectError(error.FileNotFound, layout_mod.readFile(io, root ++ "/etc/nginx/sites-enabled/other.com.conf", &out_buf));
    try std.testing.expectError(error.FileNotFound, layout_mod.readFile(io, root ++ "/etc/systemd/system/kalpanel-other.com.service", &out_buf));
    try std.testing.expectError(error.FileNotFound, layout_mod.readFile(io, root ++ "/home/bob/.kalpanel/features", &out_buf));
    const passwd_after = try layout_mod.readFile(io, root ++ "/etc/dovecot/kalpanel.passwd", &pass_buf);
    try std.testing.expect(std.mem.indexOf(u8, passwd_after, "c@other.com") == null);
    try std.testing.expectError(error.UserNotFound, exec(io, root, db_path, &.{ "user", "delete", "bob" }, null, null, &out_buf));
    try std.testing.expectError(error.UserNotFound, exec(io, root, db_path, &.{ "domain", "list", "bob" }, null, null, &out_buf));
}
