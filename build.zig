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

    const acpi_test_mod = b.createModule(.{
        .root_source_file = b.path("src/arch/acpi_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const acpi_tests = b.addTest(.{ .root_module = acpi_test_mod });
    const run_acpi_tests = b.addRunArtifact(acpi_tests);

    const ioapic_test_mod = b.createModule(.{
        .root_source_file = b.path("src/arch/ioapic_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const ioapic_tests = b.addTest(.{ .root_module = ioapic_test_mod });
    const run_ioapic_tests = b.addRunArtifact(ioapic_tests);

    const object_test_mod = b.createModule(.{
        .root_source_file = b.path("src/object/encoding_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const object_tests = b.addTest(.{ .root_module = object_test_mod });
    const run_object_tests = b.addRunArtifact(object_tests);

    const mkinitramfs_mod = b.createModule(.{
        .root_source_file = b.path("mkinitramfs.zig"),
        .target = target,
        .optimize = optimize,
    });
    const mkinitramfs_tests = b.addTest(.{ .root_module = mkinitramfs_mod });
    const run_mkinitramfs_tests = b.addRunArtifact(mkinitramfs_tests);

    const mkinitramfs_exe = b.addExecutable(.{
        .name = "mkinitramfs",
        .root_module = mkinitramfs_mod,
    });
    const pack_initramfs = b.addRunArtifact(mkinitramfs_exe);
    pack_initramfs.setCwd(b.path("."));
    pack_initramfs.addArgs(&.{ "initramfs", "zig-out/initramfs.img" });

    const initramfs_step = b.step("initramfs", "Pack initramfs/ into zig-out/initramfs.img");
    initramfs_step.dependOn(&pack_initramfs.step);

    const fs_test_mod = b.createModule(.{
        .root_source_file = b.path("src/fs/vfs_test.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fs_tests = b.addTest(.{ .root_module = fs_test_mod });
    const run_fs_tests = b.addRunArtifact(fs_tests);

    // Freestanding user program: linked at 0x400000, delivered as a module.
    const shell_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
    });
    const shell_mod = b.createModule(.{
        .root_source_file = b.path("user/shell.zig"),
        .target = shell_target,
        .optimize = .ReleaseSafe,
        .pic = false,
        .red_zone = false,
        .stack_check = false,
        .stack_protector = false,
    });
    const shell_exe = b.addExecutable(.{ .name = "shell", .root_module = shell_mod });
    shell_exe.use_llvm = true;
    shell_exe.use_lld = true;
    shell_exe.setLinkerScript(b.path("user/linker.ld"));
    shell_exe.entry = .{ .symbol_name = "_start" };
    const install_shell = b.addInstallArtifact(shell_exe, .{ .dest_sub_path = "shell.elf" });
    const shell_step = b.step("shell", "Build the user-mode shell ELF");
    shell_step.dependOn(&install_shell.step);

    const test_step = b.step("test", "Run host tests");
    test_step.dependOn(&run_check_tests.step);
    test_step.dependOn(&run_format_tests.step);
    test_step.dependOn(&run_acpi_tests.step);
    test_step.dependOn(&run_ioapic_tests.step);
    test_step.dependOn(&run_object_tests.step);
    test_step.dependOn(&run_fs_tests.step);
    test_step.dependOn(&run_mkinitramfs_tests.step);

    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
    });

    const kernel = addKernel(b, kernel_target, optimize, "kernel", .{});
    const panic_kernel = addKernel(b, kernel_target, optimize, "kernel-panic", .{ .panic_smoke = true });
    const exception_kernel = addKernel(b, kernel_target, optimize, "kernel-exception", .{ .exception_smoke = true });
    const nmi_kernel = addKernel(b, kernel_target, optimize, "kernel-nmi", .{ .nmi_smoke = true });
    const timer_kernel = addKernel(b, kernel_target, optimize, "kernel-timer", .{ .timer_smoke = true });
    const mem_kernel = addKernel(b, kernel_target, optimize, "kernel-mem", .{ .mem_smoke = true });
    const irq_kernel = addKernel(b, kernel_target, optimize, "kernel-irq", .{ .irq_smoke = true });
    const bench_kernel = addKernel(b, kernel_target, optimize, "kernel-bench", .{ .bench_smoke = true });
    const smp_kernel = addKernel(b, kernel_target, optimize, "kernel-smp", .{ .smp_smoke = true });
    const sched_kernel = addKernel(b, kernel_target, optimize, "kernel-sched", .{ .sched_smoke = true });
    const object_kernel = addKernel(b, kernel_target, optimize, "kernel-object", .{ .object_smoke = true });
    const user_kernel = addKernel(b, kernel_target, optimize, "kernel-user", .{ .user_smoke = true });
    const blk_kernel = addKernel(b, kernel_target, optimize, "kernel-blk", .{ .blk_smoke = true });
    const shell_kernel = addKernel(b, kernel_target, optimize, "kernel-shell", .{ .shell_smoke = true });

    const install_kernel = b.addInstallArtifact(kernel, .{ .dest_sub_path = "kernel.elf" });
    const install_panic_kernel = b.addInstallArtifact(panic_kernel, .{ .dest_sub_path = "kernel-panic.elf" });
    const install_exception_kernel = b.addInstallArtifact(exception_kernel, .{ .dest_sub_path = "kernel-exception.elf" });
    const install_nmi_kernel = b.addInstallArtifact(nmi_kernel, .{ .dest_sub_path = "kernel-nmi.elf" });
    const install_timer_kernel = b.addInstallArtifact(timer_kernel, .{ .dest_sub_path = "kernel-timer.elf" });
    const install_mem_kernel = b.addInstallArtifact(mem_kernel, .{ .dest_sub_path = "kernel-mem.elf" });
    const install_irq_kernel = b.addInstallArtifact(irq_kernel, .{ .dest_sub_path = "kernel-irq.elf" });
    const install_bench_kernel = b.addInstallArtifact(bench_kernel, .{ .dest_sub_path = "kernel-bench.elf" });
    const install_smp_kernel = b.addInstallArtifact(smp_kernel, .{ .dest_sub_path = "kernel-smp.elf" });
    const install_sched_kernel = b.addInstallArtifact(sched_kernel, .{ .dest_sub_path = "kernel-sched.elf" });
    const install_object_kernel = b.addInstallArtifact(object_kernel, .{ .dest_sub_path = "kernel-object.elf" });
    const install_user_kernel = b.addInstallArtifact(user_kernel, .{ .dest_sub_path = "kernel-user.elf" });
    const install_blk_kernel = b.addInstallArtifact(blk_kernel, .{ .dest_sub_path = "kernel-blk.elf" });
    const install_shell_kernel = b.addInstallArtifact(shell_kernel, .{ .dest_sub_path = "kernel-shell.elf" });

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

    const irq_kernel_step = b.step("kernel-irq", "Build the kernel with the external IRQ smoke path");
    irq_kernel_step.dependOn(&install_irq_kernel.step);

    const bench_kernel_step = b.step("kernel-bench", "Build the kernel with the benchmark path");
    bench_kernel_step.dependOn(&install_bench_kernel.step);

    const smp_kernel_step = b.step("kernel-smp", "Build the kernel with the SMP smoke path");
    smp_kernel_step.dependOn(&install_smp_kernel.step);

    const sched_kernel_step = b.step("kernel-sched", "Build the kernel with the scheduler smoke path");
    sched_kernel_step.dependOn(&install_sched_kernel.step);

    const object_kernel_step = b.step("kernel-object", "Build the kernel with the object smoke path");
    object_kernel_step.dependOn(&install_object_kernel.step);

    const user_kernel_step = b.step("kernel-user", "Build the kernel with the user-space smoke path");
    user_kernel_step.dependOn(&install_user_kernel.step);

    const blk_kernel_step = b.step("kernel-blk", "Build the kernel with the virtio-blk smoke path");
    blk_kernel_step.dependOn(&install_blk_kernel.step);

    const shell_kernel_step = b.step("kernel-shell", "Build the kernel with the user-shell smoke path");
    shell_kernel_step.dependOn(&install_shell_kernel.step);

    const smoke_cmd = b.addSystemCommand(&.{ "bash", "tests/qemu-smoke.sh" });
    smoke_cmd.setCwd(b.path("."));
    smoke_cmd.step.dependOn(&install_kernel.step);
    smoke_cmd.step.dependOn(&install_panic_kernel.step);
    smoke_cmd.step.dependOn(&install_exception_kernel.step);
    smoke_cmd.step.dependOn(&install_nmi_kernel.step);
    smoke_cmd.step.dependOn(&install_timer_kernel.step);
    smoke_cmd.step.dependOn(&install_mem_kernel.step);
    smoke_cmd.step.dependOn(&install_irq_kernel.step);
    smoke_cmd.step.dependOn(&install_smp_kernel.step);
    smoke_cmd.step.dependOn(&install_sched_kernel.step);
    smoke_cmd.step.dependOn(&install_object_kernel.step);
    smoke_cmd.step.dependOn(&install_user_kernel.step);
    smoke_cmd.step.dependOn(&install_blk_kernel.step);
    smoke_cmd.step.dependOn(&install_shell_kernel.step);
    smoke_cmd.step.dependOn(&install_shell.step);
    smoke_cmd.step.dependOn(&pack_initramfs.step);

    const smoke_step = b.step("qemu-smoke", "Boot the kernel smoke variants in QEMU");
    smoke_step.dependOn(&smoke_cmd.step);

    const bench_cmd = b.addSystemCommand(&.{ "bash", "tests/qemu-bench.sh" });
    bench_cmd.setCwd(b.path("."));
    bench_cmd.step.dependOn(&install_bench_kernel.step);

    const bench_step = b.step("bench", "Run the kernel benchmarks under QEMU icount and compare with the baseline");
    bench_step.dependOn(&bench_cmd.step);

    b.default_step.dependOn(&run_check.step);
    b.default_step.dependOn(&run_check_tests.step);
    b.default_step.dependOn(&run_format_tests.step);
    b.default_step.dependOn(&run_acpi_tests.step);
    b.default_step.dependOn(&run_ioapic_tests.step);
    b.default_step.dependOn(&run_object_tests.step);
    b.default_step.dependOn(&run_fs_tests.step);
    b.default_step.dependOn(&run_mkinitramfs_tests.step);
    b.default_step.dependOn(&install_kernel.step);
}

const SmokeOptions = struct {
    panic_smoke: bool = false,
    exception_smoke: bool = false,
    nmi_smoke: bool = false,
    timer_smoke: bool = false,
    mem_smoke: bool = false,
    irq_smoke: bool = false,
    bench_smoke: bool = false,
    smp_smoke: bool = false,
    sched_smoke: bool = false,
    object_smoke: bool = false,
    user_smoke: bool = false,
    blk_smoke: bool = false,
    shell_smoke: bool = false,
};

fn addKernel(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.Optimize,
    name: []const u8,
    smoke: SmokeOptions,
) *std.Build.Step.Compile {
    const options = b.addOptions();
    options.addOption(bool, "panic_smoke", smoke.panic_smoke);
    options.addOption(bool, "exception_smoke", smoke.exception_smoke);
    options.addOption(bool, "nmi_smoke", smoke.nmi_smoke);
    options.addOption(bool, "timer_smoke", smoke.timer_smoke);
    options.addOption(bool, "mem_smoke", smoke.mem_smoke);
    options.addOption(bool, "irq_smoke", smoke.irq_smoke);
    options.addOption(bool, "bench_smoke", smoke.bench_smoke);
    options.addOption(bool, "smp_smoke", smoke.smp_smoke);
    options.addOption(bool, "sched_smoke", smoke.sched_smoke);
    options.addOption(bool, "object_smoke", smoke.object_smoke);
    options.addOption(bool, "user_smoke", smoke.user_smoke);
    options.addOption(bool, "blk_smoke", smoke.blk_smoke);
    options.addOption(bool, "shell_smoke", smoke.shell_smoke);

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
    module.addAssemblyFile(b.path("src/arch/context.S"));
    module.addAssemblyFile(b.path("src/arch/syscall.S"));
    module.addAssemblyFile(b.path("src/arch/user_entry.S"));
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
