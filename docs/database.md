# Database Module

## Purpose

SQLite storage for users, accounts, roles, permissions, and other panel data.

## Library

**nDimensional/zig-sqlite** (v0.5.0-3530400)

- Explicitly built and tested with Zig 0.17.0
- Simple, low-level, explicitly-typed bindings
- MIT license

### Adding the dependency

From the project root:

```bash
zig fetch --save=sqlite https://github.com/nDimensional/zig-sqlite/archive/refs/tags/v0.5.0-3530400.tar.gz
```

This updates `build.zig.zon` with the correct hash.

Then in `build.zig` add:

```zig
const sqlite = b.dependency("sqlite", .{});
exe.root_module.addImport("sqlite", sqlite.module("sqlite"));
// and the same for any test modules that need it
```

## Restrictions / Rules

- Single SQLite file for the panel (lightweight, self-contained).
- Used by the user management module for accounts and permissions.
- Schema and queries live in this module; other modules access through it.
- No external database server required.

## Status

Folder and stub created. Dependency ready to be fetched. Implementation of schema and queries to follow.
