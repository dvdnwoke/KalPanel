const std = @import("std");
const layout = @import("../layout.zig");

pub const bin = "/usr/bin/node";
pub const package = "nodejs";
pub const server_js =
    \\const http = require("http");
    \\const port = process.env.PORT || "3000";
    \\http.createServer((req, res) => {
    \\  res.writeHead(200, { "Content-Type": "text/plain" });
    \\  res.end("kalpanel-node-ok\n");
    \\}).listen(Number(port), "127.0.0.1");
;

pub fn appendLocations(buf: []u8, len: *usize, port: i64) !void {
    var port_buf: [16]u8 = undefined;
    const port_txt = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    try layout.add(buf, len, "    location / {\n        proxy_pass http://127.0.0.1:");
    try layout.add(buf, len, port_txt);
    try layout.add(buf, len,
        \\;
        \\        proxy_set_header Host $host;
        \\        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        \\        proxy_set_header X-Forwarded-Proto $scheme;
        \\    }
        \\
    );
}

pub fn appendUnit(buf: []u8, len: *usize, domain: []const u8, public_path: []const u8, port: i64, user_name: []const u8) !void {
    var port_buf: [16]u8 = undefined;
    const port_txt = try std.fmt.bufPrint(&port_buf, "{d}", .{port});
    try layout.add(buf, len, "[Unit]\nDescription=KalPanel node ");
    try layout.add(buf, len, domain);
    try layout.add(buf, len, "\nAfter=network.target\n\n[Service]\nUser=");
    try layout.add(buf, len, user_name);
    try layout.add(buf, len, "\nWorkingDirectory=");
    try layout.add(buf, len, public_path);
    try layout.add(buf, len, "\nEnvironment=PORT=");
    try layout.add(buf, len, port_txt);
    try layout.add(buf, len, "\nExecStart=");
    try layout.add(buf, len, bin);
    try layout.add(buf, len, " ");
    try layout.add(buf, len, public_path);
    try layout.add(buf, len, "/server.js\nRestart=on-failure\n\n[Install]\nWantedBy=multi-user.target\n");
}
