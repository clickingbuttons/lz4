const std = @import("std");

pub fn build(b: *std.Build) void {
    // Expose to zig dependents
    _ = b.addModule("lz4", .{ .source_file = .{ .path = "src/lib.zig" } });

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const test_step = b.step("test", "Run unit tests");
    const run_tests = b.addRunArtifact(b.addTest(.{
        .root_source_file = .{ .path = "src/lib.zig" },
        .target = target,
        .optimize = optimize,
    }));
    test_step.dependOn(&run_tests.step);
}
