const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.option(
        std.builtin.Optimize,
        "optimize",
        "Prioritize performance, safety, or binary size",
    ) orelse .safe;

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

    const kernel = addKernel(b, kernel_target, optimize, "kernel", false, false, false, false, false);
    const panic_kernel = addKernel(b, kernel_target, optimize, "kernel-panic", true, false, false, false, false);
    const exception_kernel = addKernel(b, kernel_target, optimize, "kernel-exception", false, true, false, false, false);
    const nmi_kernel = addKernel(b, kernel_target, optimize, "kernel-nmi", false, false, true, false, false);
    const timer_kernel = addKernel(b, kernel_target, optimize, "kernel-timer", false, false, false, true, false);
    const mem_kernel = addKernel(b, kernel_target, optimize, "kernel-mem", false, false, false, false, true);

    const install_kernel = b.addInstallArtifact(kernel, .{ .dest_sub_path = "kernel.elf" });
    const install_panic_kernel = b.addInstallArtifact(panic_kernel, .{ .dest_sub_path = "kernel-panic.elf" });
    const install_exception_kernel = b.addInstallArtifact(exception_kernel, .{ .dest_sub_path = "kernel-exception.elf" });
    const install_nmi_kernel = b.addInstallArtifact(nmi_kernel, .{ .dest_sub_path = "kernel-nmi.elf" });
    const install_timer_kernel = b.addInstallArtifact(timer_kernel, .{ .dest_sub_path = "kernel-timer.elf" });
    const install_mem_kernel = b.addInstallArtifact(mem_kernel, .{ .dest_sub_path = "kernel-mem.elf" });

    const kernel_step = b.step("kernel", "Build the freestanding kernel");
    kernel_step.dependOn(&install_kernel.step);

    const panic_kernel_step = b.step("kernel-panic", "Build the kernel with the panic smoke path");
    panic_kernel_step.dependOn(&install_panic_kernel.step);

    const exception_kernel_step = b.step("kernel-exception", "Build the kernel with the exception smoke path");
    exception_kernel_step.dependOn(&install_exception_kernel.step);

    const nmi_kernel_step = b.step("kernel-nmi", "Build the kernel with the NMI/IST smoke path");
    nmi_kernel_step.dependOn(&install_nmi_kernel.step);

    const timer_kernel_step = b.step("kernel-timer", "Build the kernel with the APIC timer smoke path");
    timer_kernel_step.dependOn(&install_timer_kernel.step);

    const mem_kernel_step = b.step("kernel-mem", "Build the kernel with the memory smoke path");
    mem_kernel_step.dependOn(&install_mem_kernel.step);

    const smoke_cmd = b.addSystemCommand(&.{ "bash", "tests/qemu-smoke.sh" });
    smoke_cmd.setCwd(b.path("."));
    smoke_cmd.step.dependOn(&install_kernel.step);
    smoke_cmd.step.dependOn(&install_panic_kernel.step);
    smoke_cmd.step.dependOn(&install_exception_kernel.step);
    smoke_cmd.step.dependOn(&install_nmi_kernel.step);
    smoke_cmd.step.dependOn(&install_timer_kernel.step);
    smoke_cmd.step.dependOn(&install_mem_kernel.step);

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
    optimize: std.builtin.Optimize,
    name: []const u8,
    panic_smoke: bool,
    exception_smoke: bool,
    nmi_smoke: bool,
    timer_smoke: bool,
    mem_smoke: bool,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption(bool, "panic_smoke", panic_smoke);
    options.addOption(bool, "exception_smoke", exception_smoke);
    options.addOption(bool, "nmi_smoke", nmi_smoke);
    options.addOption(bool, "timer_smoke", timer_smoke);
    options.addOption(bool, "mem_smoke", mem_smoke);

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .kernel,
        .pic = false,
        .red_zone = false,
        .stack_check = false,
        .omit_frame_pointer = false,
    });
    module.addImport("config", options.createModule());
    module.addAssemblyFile(b.path("src/arch/exceptions.S"));
    module.addAssemblyFile(b.path("src/arch/irqs.S"));
    module.addAssemblyFile(b.path("src/arch/pf.S"));
    module.addAssemblyFile(b.path("src/arch/segments.S"));

    const exe = b.addExecutable(.{
        .name = name,
        .root_module = module,
    });
    // The self-hosted ELF linker does not apply the custom script yet; the
    // script also requires the LLVM backend for LLD.
    exe.use_llvm = true;
    exe.use_lld = true;
    exe.setLinkerScript(b.path("src/arch/linker.ld"));
    // _start is the naked trampoline that enables SSE and selects the kernel stack.
    exe.entry = .{ .symbol_name = "_start" };
    return exe;
}
