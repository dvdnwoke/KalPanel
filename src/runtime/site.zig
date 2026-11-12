const layout = @import("../layout.zig");
const php = @import("php.zig");
const node = @import("node.zig");

pub const Certs = struct {
    fullchain: []const u8,
    privkey: []const u8,
};

/// Port 80 always serves the HTTP-01 challenge directory.
/// When `certs` is set, everything else redirects to a TLS server on 443.
pub fn append(
    buf: []u8,
    len: *usize,
    name: []const u8,
    public_path: []const u8,
    is_php: bool,
    node_port: i64,
    certs: ?Certs,
) !void {
    try layout.add(buf, len, "server {\n    listen 80;\n    listen [::]:80;\n    server_name ");
    try layout.add(buf, len, name);
    try layout.add(buf, len, ";\n    location ^~ /.well-known/acme-challenge/ {\n        root ");
    try layout.add(buf, len, public_path);
    try layout.add(buf, len, ";\n        default_type \"text/plain\";\n    }\n");
    if (certs) |tls| {
        try layout.add(buf, len, "    location / {\n        return 301 https://$host$request_uri;\n    }\n}\nserver {\n    listen 443 ssl;\n    listen [::]:443 ssl;\n    server_name ");
        try layout.add(buf, len, name);
        try layout.add(buf, len, ";\n    ssl_certificate ");
        try layout.add(buf, len, tls.fullchain);
        try layout.add(buf, len, ";\n    ssl_certificate_key ");
        try layout.add(buf, len, tls.privkey);
        try layout.add(buf, len, ";\n    ssl_protocols TLSv1.2 TLSv1.3;\n");
    }
    if (is_php) {
        try php.appendLocations(buf, len, public_path, certs != null);
    } else {
        try node.appendLocations(buf, len, node_port);
    }
    try layout.add(buf, len, "}\n");
}
