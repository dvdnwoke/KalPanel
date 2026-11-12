# Dependencies Module

## Purpose

Manages external program dependencies (nginx, postfix, php-fpm, nodejs, etc.) required by KalPanel features.

## Restrictions / Rules

- A dependency is only installed or checked if **at least one user** has the corresponding feature enabled.
- If no user is using domains, domain-related packages are not installed.
- Same for email, PHP, Node.js, and any future features.
- Each feature has its own file (`domain.zig`, `email.zig`, `php.zig`, `node.zig`) that implements the common `Dependency` interface.
- The interface provides: name, feature enum, package list, `check()`, and `install()`.
- Manager filters and ensures only the required set.

## Interface

```zig
pub const Dependency = struct {
    name: []const u8,
    feature: Feature,
    packages: []const []const u8,
    check: *const fn () bool,
    install: *const fn () !void,
};
```

## Testing

- Unit tests cover feature set construction and filtering.
- Randomized (fuzzy-style) tests verify that only enabled features produce dependencies across many random configurations.
- Tests run via `zig build test` and in GitHub Actions on every push/PR.

## Current Status

Bootstrap implementation. Check/install functions are stubs that log; real package detection and installation (apt/yum/etc.) will be added later.
