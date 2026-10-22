const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const check_mod = b.createModule(.{
        .root_source_file = b.path("tools/check_deps.zig"),
        .target = target,
        .optimize = optimize,
    });

    const check_exe = b.addExecutable(.{
        .name = "check-deps",
        .root_module = check_mod,
    });

    const run_check = b.addRunArtifact(check_exe);
    run_check.setCwd(b.path("."));
    run_check.addArg("src");

    const check_step = b.step("check-deps", "Verify the kernel module dependency DAG");
    check_step.dependOn(&run_check.step);

    const tests = b.addTest(.{ .root_module = check_mod });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run host tests");
    test_step.dependOn(&run_tests.step);

    b.default_step.dependOn(&run_check.step);
    b.default_step.dependOn(&run_tests.step);
}
