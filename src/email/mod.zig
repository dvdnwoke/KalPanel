const std = @import("std");
const sqlite = @import("sqlite");
const Db = @import("../database/mod.zig").Db;
const users = @import("../user/mod.zig");
const layout_mod = @import("../layout.zig");
const tls_mod = @import("../tls.zig");
const domain_mod = @import("../domain/mod.zig");

pub fn create(db: *Db, io: std.Io, layout: layout_mod.Layout, address: []const u8, password_buf: []u8) ![]const u8 {
    const at = std.mem.indexOfScalar(u8, address, '@') orelse return error.InvalidAddress;
    const local = address[0..at];
    const domain_name = address[at + 1 ..];
    try validateAddress(address);

    const domain = (try findDomain(db, domain_name)) orelse return error.DomainNotFound;
    if (domain.suspended) return error.DomainSuspended;
    if (domain.user_suspended) return error.UserSuspended;

    var home_buf: [512]u8 = undefined;
    const account = (try users.lookup(db, domain.user_name_buf[0..domain.user_name_len], &home_buf)) orelse return error.UserNotFound;
    const features = try users.featuresFor(db, account.id);
    if (!features.email) return error.FeatureNotEnabled;
    if (try addressTaken(db, address)) return error.EmailExists;

    if (password_buf.len < 18) return error.PasswordBufferTooSmall;
    var raw: [9]u8 = undefined;
    var random = std.Random.IoSource{ .io = io };
    random.interface().bytes(&raw);
    const password = hex(&raw, password_buf);

    var hash_buf: [64]u8 = undefined;
    const hash = sha256B64(password, &hash_buf);

    try db.raw.exec(
        "INSERT INTO emails (domain_id, local_part, address, password_sha256) VALUES (:domain_id, :local_part, :address, :password_sha256)",
        .{
            .domain_id = domain.id,
            .local_part = sqlite.text(local),
            .address = sqlite.text(address),
            .password_sha256 = sqlite.text(hash),
        },
    );
    try reload(db, io, layout);
    return password;
}

pub fn suspendName(db: *Db, io: std.Io, layout: layout_mod.Layout, address: []const u8) !void {
    if (!try addressTaken(db, address)) return error.EmailNotFound;
    try db.raw.exec(
        "UPDATE emails SET suspended = 1 WHERE address = :address",
        .{ .address = sqlite.text(address) },
    );
    try reload(db, io, layout);
}

pub fn sha256B64(password: []const u8, buf: []u8) []const u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &digest, .{});
    return std.base64.standard.Encoder.encode(buf, &digest);
}

const DomainRow = struct {
    id: i64,
    suspended: bool,
    user_suspended: bool,
    user_name_len: usize,
    user_name_buf: [64]u8 = undefined,
};

fn findDomain(db: *Db, name: []const u8) !?DomainRow {
    const query = try db.raw.prepare(
        struct { name: sqlite.Text },
        struct { id: i64, suspended: i64, user_suspended: i64, user_name: sqlite.Text },
        "SELECT d.id AS id, d.suspended AS suspended, COALESCE(f.suspended, 0) AS user_suspended, u.name AS user_name " ++
            "FROM domains d JOIN users u ON u.id = d.user_id LEFT JOIN user_flags f ON f.user_id = u.id WHERE d.name = :name",
    );
    defer query.finalize();
    try query.bind(.{ .name = sqlite.text(name) });
    defer query.reset();
    const row = (try query.step()) orelse return null;
    var out = DomainRow{
        .id = row.id,
        .suspended = row.suspended != 0,
        .user_suspended = row.user_suspended != 0,
        .user_name_len = row.user_name.data.len,
    };
    if (row.user_name.data.len > out.user_name_buf.len) return error.NameTooLong;
    @memcpy(out.user_name_buf[0..row.user_name.data.len], row.user_name.data);
    return out;
}

pub fn reload(db: *Db, io: std.Io, layout: layout_mod.Layout) !void {
    var tls_name: [253]u8 = undefined;
    const tls_domain = try tls_mod.firstDomain(db, &tls_name);
    var cert_full_buf: [512]u8 = undefined;
    var cert_key_buf: [512]u8 = undefined;
    const cert_full = if (tls_domain) |name| try tls_mod.fullchainPath(layout, &cert_full_buf, name) else null;
    const cert_key = if (tls_domain) |name| try tls_mod.privkeyPath(layout, &cert_key_buf, name) else null;
    var domains_body: [4096]u8 = undefined;
    var boxes_body: [4096]u8 = undefined;
    var passwd_body: [4096]u8 = undefined;
    var domains_len: usize = 0;
    var boxes_len: usize = 0;
    var passwd_len: usize = 0;

    const query = try db.raw.prepare(
        struct {},
        struct {
            address: sqlite.Text,
            local_part: sqlite.Text,
            password_sha256: sqlite.Text,
            domain: sqlite.Text,
            suspended: i64,
            domain_suspended: i64,
            user_suspended: i64,
        },
        "SELECT e.address AS address, e.local_part AS local_part, e.password_sha256 AS password_sha256, d.name AS domain, e.suspended AS suspended, d.suspended AS domain_suspended, COALESCE(f.suspended, 0) AS user_suspended " ++
            "FROM emails e JOIN domains d ON d.id = e.domain_id JOIN users u ON u.id = d.user_id LEFT JOIN user_flags f ON f.user_id = u.id",
    );
    defer query.finalize();
    try query.bind(.{});
    defer query.reset();

    while (try query.step()) |row| {
        if (row.suspended != 0 or row.domain_suspended != 0 or row.user_suspended != 0) continue;
        if (!containsLine(domains_body[0..domains_len], row.domain.data)) {
            try layout_mod.add(&domains_body, &domains_len, row.domain.data);
            try layout_mod.add(&domains_body, &domains_len, "\n");
        }
        try layout_mod.add(&boxes_body, &boxes_len, row.address.data);
        try layout_mod.add(&boxes_body, &boxes_len, " ");
        try layout_mod.add(&boxes_body, &boxes_len, row.domain.data);
        try layout_mod.add(&boxes_body, &boxes_len, "/");
        try layout_mod.add(&boxes_body, &boxes_len, row.local_part.data);
        try layout_mod.add(&boxes_body, &boxes_len, "/\n");
        try layout_mod.add(&passwd_body, &passwd_len, row.address.data);
        try layout_mod.add(&passwd_body, &passwd_len, ":{SHA256}");
        try layout_mod.add(&passwd_body, &passwd_len, row.password_sha256.data);
        try layout_mod.add(&passwd_body, &passwd_len, "::::::\n");

        var mail_rel: [256]u8 = undefined;
        const rel = try std.fmt.bufPrint(&mail_rel, "var/mail/kalpanel/{s}/{s}", .{ row.domain.data, row.local_part.data });
        var mail_path: [512]u8 = undefined;
        const full = try layout.resolve(&mail_path, rel);
        try std.Io.Dir.cwd().createDirPath(io, full);
    }

    var path_buf: [512]u8 = undefined;
    const domains_path = try layout.resolve(&path_buf, "etc/postfix/kalpanel-virtual-domains");
    try layout_mod.writeFile(io, domains_path, domains_body[0..domains_len]);

    var path_buf2: [512]u8 = undefined;
    const boxes_path = try layout.resolve(&path_buf2, "etc/postfix/kalpanel-virtual-mailboxes");
    try layout_mod.writeFile(io, boxes_path, boxes_body[0..boxes_len]);

    var path_buf3: [512]u8 = undefined;
    const passwd_path = try layout.resolve(&path_buf3, "etc/dovecot/kalpanel.passwd");
    try layout_mod.writeFile(io, passwd_path, passwd_body[0..passwd_len]);

    var base_buf: [512]u8 = undefined;
    const base = try layout.resolve(&base_buf, "var/mail/kalpanel");
    var conf: [2048]u8 = undefined;
    var conf_len: usize = 0;
    try layout_mod.add(&conf, &conf_len, "inet_interfaces = all\nvirtual_mailbox_domains = hash:");
    try layout_mod.add(&conf, &conf_len, domains_path);
    try layout_mod.add(&conf, &conf_len, "\nvirtual_mailbox_maps = hash:");
    try layout_mod.add(&conf, &conf_len, boxes_path);
    try layout_mod.add(&conf, &conf_len, "\nvirtual_mailbox_base = ");
    try layout_mod.add(&conf, &conf_len, base);
    try layout_mod.add(&conf, &conf_len, "\nvirtual_uid_maps = static:5000\nvirtual_gid_maps = static:5000\n");
    if (cert_full) |full| {
        try layout_mod.add(&conf, &conf_len, "smtpd_tls_cert_file = ");
        try layout_mod.add(&conf, &conf_len, full);
        try layout_mod.add(&conf, &conf_len, "\nsmtpd_tls_key_file = ");
        try layout_mod.add(&conf, &conf_len, cert_key.?);
        try layout_mod.add(&conf, &conf_len, "\n");
    }

    var cf_buf: [512]u8 = undefined;
    const cf_path = try layout.resolve(&cf_buf, "etc/postfix/kalpanel.cf");
    try layout_mod.writeFile(io, cf_path, conf[0..conf_len]);

    var master: [1024]u8 = undefined;
    var master_len: usize = 0;
    try layout_mod.add(&master, &master_len,
        \\submission inet n       -       y       -       -       smtpd
        \\  -o syslog_name=postfix/submission
        \\  -o smtpd_tls_security_level=encrypt
        \\  -o smtpd_sasl_auth_enable=yes
        \\  -o smtpd_sasl_type=dovecot
        \\  -o smtpd_sasl_path=private/auth
        \\  -o smtpd_recipient_restrictions=permit_sasl_authenticated,reject
        \\
    );
    var master_buf: [512]u8 = undefined;
    const master_path = try layout.resolve(&master_buf, "etc/postfix/kalpanel-master.cf");
    try layout_mod.writeFile(io, master_path, master[0..master_len]);

    var dove: [2048]u8 = undefined;
    var dove_len: usize = 0;
    try layout_mod.add(&dove, &dove_len, "protocols = imap\nlisten = *\nssl = required\n");
    if (cert_full) |full| {
        try layout_mod.add(&dove, &dove_len, "ssl_cert = <");
        try layout_mod.add(&dove, &dove_len, full);
        try layout_mod.add(&dove, &dove_len, "\nssl_key = <");
        try layout_mod.add(&dove, &dove_len, cert_key.?);
        try layout_mod.add(&dove, &dove_len, "\n");
    } else {
        try layout_mod.add(&dove, &dove_len, "ssl_cert = </etc/ssl/certs/ssl-cert-snakeoil.pem\nssl_key = </etc/ssl/private/ssl-cert-snakeoil.key\n");
    }
    try layout_mod.add(&dove, &dove_len, "mail_location = maildir:");
    try layout_mod.add(&dove, &dove_len, base);
    try layout_mod.add(&dove, &dove_len, "/%d/%n\npassdb {\n  driver = passwd-file\n  args = username_format=%u ");
    try layout_mod.add(&dove, &dove_len, passwd_path);
    try layout_mod.add(&dove, &dove_len,
        \\
        \\}
        \\userdb {
        \\  driver = static
        \\  args = uid=vmail gid=vmail home=
    );
    try layout_mod.add(&dove, &dove_len, base);
    try layout_mod.add(&dove, &dove_len,
        \\/%d/%n
        \\}
        \\service imap-login {
        \\  inet_listener imaps {
        \\    port = 993
        \\  }
        \\}
        \\service auth {
        \\  unix_listener /var/spool/postfix/private/auth {
        \\    mode = 0660
        \\    user = postfix
        \\    group = postfix
        \\  }
        \\}
        \\
    );
    var dove_buf: [512]u8 = undefined;
    const dove_path = try layout.resolve(&dove_buf, "etc/dovecot/conf.d/99-kalpanel.conf");
    try layout_mod.writeFile(io, dove_path, dove[0..dove_len]);
}

fn containsLine(body: []const u8, domain: []const u8) bool {
    var it = std.mem.splitScalar(u8, body, '\n');
    while (it.next()) |line| {
        if (std.mem.eql(u8, line, domain)) return true;
    }
    return false;
}

fn addressTaken(db: *Db, address: []const u8) !bool {
    const query = try db.raw.prepare(
        struct { address: sqlite.Text },
        struct { id: i64 },
        "SELECT id FROM emails WHERE address = :address",
    );
    defer query.finalize();
    try query.bind(.{ .address = sqlite.text(address) });
    defer query.reset();
    return (try query.step()) != null;
}

pub fn validateAddress(address: []const u8) !void {
    const at = std.mem.indexOfScalar(u8, address, '@') orelse return error.InvalidAddress;
    if (at == 0 or std.mem.indexOfScalar(u8, address[at + 1 ..], '@') != null) return error.InvalidAddress;
    try validateLocal(address[0..at]);
    domain_mod.validateDomain(address[at + 1 ..]) catch return error.InvalidAddress;
}

fn validateLocal(local: []const u8) !void {
    if (local.len == 0 or local.len > 64) return error.InvalidAddress;
    if (local[0] == '.' or local[local.len - 1] == '.') return error.InvalidAddress;
    var prev_dot = false;
    for (local) |c| {
        if (c == '.') {
            if (prev_dot) return error.InvalidAddress;
            prev_dot = true;
            continue;
        }
        prev_dot = false;
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
        if (!ok) return error.InvalidAddress;
    }
}

fn hex(raw: []const u8, out: []u8) []const u8 {
    const digits = "0123456789abcdef";
    for (raw, 0..) |byte, i| {
        out[i * 2] = digits[byte >> 4];
        out[i * 2 + 1] = digits[byte & 0xf];
    }
    return out[0 .. raw.len * 2];
}
