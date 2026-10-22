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

    const check_tests = b.addTest(.{ .root_module = check_mod });
    const run_check_tests = b.addRunArtifact(check_tests);

    const format_test_mod = b.createModule(.{
        .root_source_file = b.path("src/lib/format_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const format_tests = b.addTest(.{ .root_module = format_test_mod });
    const run_format_tests = b.addRunArtifact(format_tests);

    const test_step = b.step("test", "Run host tests");
    test_step.dependOn(&run_check_tests.step);
    test_step.dependOn(&run_format_tests.step);

    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
    });

    const kernel = addKernel(b, kernel_target, optimize, "kernel", false);
    const panic_kernel = addKernel(b, kernel_target, optimize, "kernel-panic", true);

    const install_kernel = b.addInstallArtifact(kernel, .{ .dest_sub_path = "kernel.elf" });
    const install_panic_kernel = b.addInstallArtifact(panic_kernel, .{ .dest_sub_path = "kernel-panic.elf" });

    const kernel_step = b.step("kernel", "Build the freestanding M0 kernel");
    kernel_step.dependOn(&install_kernel.step);

    const panic_kernel_step = b.step("kernel-panic", "Build the kernel with the panic smoke path");
    panic_kernel_step.dependOn(&install_panic_kernel.step);

    const smoke_cmd = b.addSystemCommand(&.{ "bash", "tests/qemu-smoke.sh" });
    smoke_cmd.setCwd(b.path("."));
    smoke_cmd.step.dependOn(&install_kernel.step);
    smoke_cmd.step.dependOn(&install_panic_kernel.step);

    const smoke_step = b.step("qemu-smoke", "Boot the M0 kernel and panic path in QEMU");
    smoke_step.dependOn(&smoke_cmd.step);

    b.default_step.dependOn(&run_check.step);
    b.default_step.dependOn(&run_check_tests.step);
    b.default_step.dependOn(&run_format_tests.step);
    b.default_step.dependOn(&install_kernel.step);
}

fn addKernel(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    name: []const u8,
    panic_smoke: bool,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption(bool, "panic_smoke", panic_smoke);

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .pic = false,
        .red_zone = false,
        .stack_check = false,
        .omit_frame_pointer = false,
        .single_threaded = true,
    });
    module.addImport("config", options.createModule());

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = module,
    });
    // The self-hosted ELF linker does not apply the custom script yet; the
    // script also requires the LLVM backend for LLD.
    exe.use_llvm = true;
    exe.use_lld = true;
    exe.setLinkerScript(b.path("src/arch/linker.ld"));
    exe.entry = .{ .symbol_name = "kmain" };
    return exe;
}
