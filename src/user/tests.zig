const std = @import("std");
const Db = @import("../database/mod.zig").Db;
const user = @import("mod.zig");
const ubuntu = @import("ubuntu.zig");

const TempHost = struct {
    root: []const u8,

    pub fn home(self: TempHost, io: std.Io, name: []const u8, buf: []u8) ![]const u8 {
        const path = try std.fmt.bufPrint(buf, "{s}/{s}", .{ self.root, name });
        try std.Io.Dir.cwd().createDirPath(io, path);
        return path;
    }

    pub fn rollback(self: TempHost, io: std.Io, name: []const u8) void {
        var buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ self.root, name }) catch return;
        std.Io.Dir.cwd().deleteTree(io, path) catch {};
    }
};

fn openTestDb() !Db {
    return Db.open(":memory:");
}

fn readFeaturesFile(io: std.Io, home_path: []const u8, buf: []u8) ![]u8 {
    var path_buf: [256]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/.kalpanel/features", .{home_path});
    var file = try std.Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    const n = try file.readPositionalAll(io, buf, 0);
    return buf[0..n];
}

test "rejects unsafe account names" {
    const bad = [_][]const u8{ "", "Admin", "a b", "1abc", "-bob", "a/b", "this-name-is-way-too-long-for-linux" };
    for (bad) |name| {
        try std.testing.expectError(error.InvalidName, user.validateName(name));
    }
    try user.validateName("alice");
    try user.validateName("bob_1");
}

test "reseller can only create a normal user" {
    try user.authorize(.admin, .admin);
    try user.authorize(.admin, .reseller);
    try user.authorize(.admin, .user);
    try user.authorize(.reseller, .user);
    try user.authorize(null, .admin);
    try std.testing.expectError(error.Forbidden, user.authorize(.reseller, .admin));
    try std.testing.expectError(error.Forbidden, user.authorize(.reseller, .reseller));
}

test "ubuntu useradd creates a home under /home" {
    var args: [7][]const u8 = undefined;
    ubuntu.fillUseraddArgs("alice", "/home/alice", &args);
    try std.testing.expectEqualStrings("useradd", args[0]);
    try std.testing.expectEqualStrings("-m", args[1]);
    try std.testing.expectEqualStrings("-d", args[2]);
    try std.testing.expectEqualStrings("/home/alice", args[3]);
    try std.testing.expectEqualStrings("-s", args[4]);
    try std.testing.expectEqualStrings("/bin/bash", args[5]);
    try std.testing.expectEqualStrings("alice", args[6]);
}

test "os-release parser accepts only ubuntu" {
    try std.testing.expectEqualStrings("ubuntu", ubuntu.idFromOsRelease("NAME=\"Ubuntu\"\nID=ubuntu\n").?);
    try std.testing.expectEqualStrings("ubuntu", ubuntu.idFromOsRelease("ID=\"ubuntu\"\n").?);
    try std.testing.expectEqualStrings("debian", ubuntu.idFromOsRelease("ID=debian\n").?);
    try std.testing.expect(ubuntu.idFromOsRelease("PRETTY_NAME=\"x\"\n") == null);
}

test "creates admin reseller and user with home features" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const root = "/tmp/kalpanel-user-test";
    std.Io.Dir.cwd().deleteTree(io, root) catch {};
    try std.Io.Dir.cwd().createDirPath(io, root);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch {};

    var db = try openTestDb();
    defer db.close();

    const host = TempHost{ .root = root };

    var home_buf: [256]u8 = undefined;
    const admin = try user.create(&db, io, host, .{
        .name = "admin",
        .role = .admin,
        .features = .{ .domain = true },
    }, &home_buf);
    try std.testing.expectEqual(@as(i64, 1), admin.id);
    try std.testing.expect(admin.features.domain);
    try std.testing.expect(!admin.features.email);

    var file_buf: [64]u8 = undefined;
    const admin_file = try readFeaturesFile(io, admin.home, &file_buf);
    try std.testing.expectEqualStrings("domain\n", admin_file);

    var reseller_home: [256]u8 = undefined;
    const reseller = try user.create(&db, io, host, .{
        .name = "shop",
        .role = .reseller,
        .features = .{ .email = true },
        .actor = .admin,
    }, &reseller_home);
    try std.testing.expectEqual(user.Role.reseller, reseller.role);

    var user_home: [256]u8 = undefined;
    const normal = try user.create(&db, io, host, .{
        .name = "alice",
        .role = .user,
        .features = .{ .php = true, .node = true },
        .actor = .reseller,
    }, &user_home);
    try std.testing.expectEqual(@as(i64, 3), normal.id);

    const alice_features = try user.featuresFor(&db, normal.id);
    try std.testing.expect(alice_features.php and alice_features.node);
    try std.testing.expect(!alice_features.domain and !alice_features.email);

    const alice_file = try readFeaturesFile(io, normal.home, &file_buf);
    try std.testing.expectEqualStrings("php\nnode\n", alice_file);

    const used = try user.featuresInUse(&db);
    try std.testing.expect(used.domain and used.email and used.php and used.node);

    var dup_home: [256]u8 = undefined;
    try std.testing.expectError(error.UserExists, user.create(&db, io, host, .{
        .name = "alice",
        .role = .user,
        .actor = .admin,
    }, &dup_home));

    try std.testing.expectError(error.Forbidden, user.create(&db, io, host, .{
        .name = "bob",
        .role = .reseller,
        .actor = .reseller,
    }, &dup_home));
}
