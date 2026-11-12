# KalPanel

Light, easy, and fast open-source hosting control panel written in Zig.

## Build

Requires Zig 0.17+.

```bash
zig build
zig build run
zig build test
```

## Status

CLI creates and suspends users, domains, and mailboxes. One PHP version (8.3) and one Node.js binary (`/usr/bin/node`) serve each domain's public folder through nginx on port 80. Setup installs only missing packages for features a non-suspended user actually has, and records those packages so uninstall removes nothing else.

On an Ubuntu host, run as root with an empty `--root` (the default). `setup` then starts nginx, `php8.3-fpm`, the node unit, postfix, and dovecot. Point the domain's A record at the server and open ports 80, 25, 587, and 993.

```bash
zig build
./zig-out/bin/kalpanel --db /var/lib/kalpanel.sqlite user create admin --role admin --domain --email --php --node
./zig-out/bin/kalpanel --db /var/lib/kalpanel.sqlite setup
./zig-out/bin/kalpanel --db /var/lib/kalpanel.sqlite domain create admin example.com --runtime php
./zig-out/bin/kalpanel --db /var/lib/kalpanel.sqlite domain create admin app.example.com --runtime node
./zig-out/bin/kalpanel --db /var/lib/kalpanel.sqlite email create alice@example.com
```

All design notes and module restrictions live in the KalPanel Google Doc.
