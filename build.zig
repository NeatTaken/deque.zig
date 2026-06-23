const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("deque", .{
        .root_source_file = b.path("src/deque.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_mod = b.createModule(.{
        .root_source_file = b.path("test/test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("deque", mod);

    const test_exe = b.addTest(.{
        .root_module = test_mod,
    });

    const test_cmd = b.addRunArtifact(test_exe);

    const test_step = b.step("test", "Run the tests.");

    test_step.dependOn(&test_cmd.step);
}
