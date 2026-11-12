const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe = b.addExecutable(.{
        .name = "kalpanel",
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Make dependencies module available
    exe.root_module.addImport("dependencies", b.createModule(.{
        .root_source_file = b.path("src/dependencies/manager.zig"),
        .imports = &.{},
    }));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the KalPanel CLI");
    run_step.dependOn(&run_cmd.step);

    // Tests
    const tests = b.addTest(.{
        .root_source_file = b.path("src/dependencies/tests.zig"),
        .target = target,
        .optimize = optimize,
    });
    tests.root_module.addImport("dependencies", b.createModule(.{
        .root_source_file = b.path("src/dependencies/manager.zig"),
    }));

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
