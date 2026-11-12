# KalPanel

**A Light, Easy, and Fast Hosting Control Panel**

KalPanel takes its name from three core principles: light, easy, and fast. We are building an open-source control panel in Zig to replace cPanel for our hosting needs. Zig was chosen for its performance, small footprint, and simplicity—qualities that directly align with our vision.

## Core Features

- **Domain & Subdomain Management** – Full support for creating and managing domains and subdomains.
- **Email Hosting** – Automatically install and configure open-source mail tools such as Exim or Postfix, then create and manage email accounts directly from the panel.
- **Runtime Flexibility** – Host both PHP and Node.js applications, with room to extend to other runtimes as needed.
- **Account Creation with Permissions** – When creating an account, you define exactly what the user can do: manage domains, create email accounts, and choose available runtimes (PHP, Node.js, etc.).
- **Built-in Reseller Support** – Three user roles are supported from day one: Admin, Reseller, and Normal User. This avoids future architectural headaches and keeps multi-tenant management clean.
- **SQLite User Database** – Lightweight, fast, and self-contained, SQLite stores all user and account data.

## Architecture & Extensibility

- **CLI-First Design** – The core of KalPanel is written in Zig and exposes a command-line interface (CLI). All core access and interaction happen through this CLI.
- **Build Your Own Interface** – Because the CLI is the primary interface, you can easily build a web UI on top of it—for example, a Node.js application. The core remains lean, while extensions are optional.
- **Extendable by Nature** – One can choose to extend KalPanel without touching the core, keeping the system modular and maintainable.

## Our Philosophy

Everything about KalPanel is guided by our name: fast, easy, and light. No bloat, no unnecessary dependencies—just a small, efficient control panel that does what you need and stays out of your way.

## Project Structure

```
.
├── build.zig
├── build.zig.zon
├── README.md
└── src/
    ├── main.zig
    ├── features.zig
    ├── database/         # SQLite (nDimensional/zig-sqlite)
    ├── dependencies/     # External program deps (feature-gated)
    ├── user/
    ├── domain/
    ├── runtime/
    └── email/
```

## Building

Requires Zig 0.17 or later.

```bash
# First time: add SQLite dependency
zig fetch --save=sqlite https://github.com/nDimensional/zig-sqlite/archive/refs/tags/v0.5.0-3530400.tar.gz

zig build
zig build run
zig build test
```

## Status

- Dependencies module: implemented (feature-gated install)
- Database module: folder + stub added, ready for zig-sqlite
- Other modules: placeholders

## License

Open source (license TBD).
