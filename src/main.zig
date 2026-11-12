const std = @import("std");
const cli = @import("cli/mod.zig");

pub fn main(init: std.process.Init) !void {
    var it = std.process.Args.Iterator.init(init.minimal.args);
    var args: [24][]const u8 = undefined;
    var n: usize = 0;
    while (it.next()) |arg| {
        if (n >= args.len) return error.TooManyArgs;
        args[n] = arg;
        n += 1;
    }

    var out_buf: [16384]u8 = undefined;
    var out = cli.Out{ .buf = &out_buf };
    cli.run(init.gpa, init.io, args[0..n], &out) catch |err| {
        if (out.len > 0) std.debug.print("{s}", .{out.slice()});
        return err;
    };
    if (out.len > 0) std.debug.print("{s}", .{out.slice()});
}
