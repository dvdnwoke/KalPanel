const layout = @import("../layout.zig");

pub const version = "8.3";
pub const socket = "unix:/run/php/php8.3-fpm.sock";
pub const index_php =
    \\<?php
    \\echo "kalpanel-php-ok";
;

pub fn appendLocations(buf: []u8, len: *usize, public_path: []const u8, https: bool) !void {
    try layout.add(buf, len, "    root ");
    try layout.add(buf, len, public_path);
    try layout.add(buf, len,
        \\;
        \\    index index.php index.html;
        \\    location / {
        \\        try_files $uri $uri/ /index.php?$query_string;
        \\    }
        \\    location ~ \.php$ {
        \\        include fastcgi_params;
        \\        fastcgi_param SCRIPT_FILENAME $document_root$fastcgi_script_name;
        \\        fastcgi_pass 
    );
    try layout.add(buf, len, socket);
    try layout.add(buf, len, ";\n");
    if (https) try layout.add(buf, len, "        fastcgi_param HTTPS on;\n");
    try layout.add(buf, len, "    }\n");
}
