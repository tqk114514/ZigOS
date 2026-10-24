# AGENTS.md

本文件是 AI 代理进入本仓库的入口。它不替代项目文档；冲突时优先级为 `CHARTER.md` > `ENGINEERING.md` > `ARCHITECTURE.md` > 本文件。

## 项目

面向 QEMU/virt 的 x86_64 模块化宏内核，Zig 0.17.0。M1 已完成（M0 启动、M1 内存/中断、内存压力与性能基准门禁全部落地）。M2 已完成：SMP 启动/per-CPU、IRQ 安全自旋锁与分配器加锁、抢占式调度器核心与 IPI、睡眠/唤醒与等待队列、对象/句柄核心、用户地址空间与 copy_from_user/copy_to_user、syscall 入口、ring3 用户程序与用户态定时抢占已落地。M2 遗留已清空（ADR-0016/0017/0018：TLB shootdown、双地址空间、堆统计、syscall 句柄、每线程内核栈与 guard page、槽位回收）；M3 进行中：只读 VFS 与打包 initramfs（Limine 模块加载、按需镜像）、virtio-blk 设备发现（ACPI MCFG/ECAM、现代 PCI 能力、BAR 映射）已落地；virtio-blk 队列读取与用户态 shell 未开始。

v1 = M0 启动 → M1 内存/中断 → M2 SMP/调度/syscall/用户态 → M3 VFS/virtio-blk/shell。网络、可写文件系统、真实硬件、多架构在 v1 之后。v1 明确不做 POSIX/GUI/USB/热加载模块/微内核 IPC；范围变更必须走 ADR。

## 开始改动前

1. 读 [CHARTER](docs/CHARTER.md)。
2. 读 [ARCHITECTURE](docs/ARCHITECTURE.md) 的依赖图。
3. 涉及具体规则时读 [ENGINEERING](docs/ENGINEERING.md)。
4. 架构、依赖图、工具链、性能/安全取舍、非目标变更：先写 [ADR](docs/adr/)。

按 M0–M3 交付可运行增量；每个里程碑必须有验收物。不要提前铺大量不可运行的骨架代码。

## 硬约束

违反以下规则的代码不能合入：

- Zig 版本 0.17.0。不升级编译器、不加外部包、不引入 libc 或动态链接。
- 模块依赖只能按 DAG。跨模块 import 只能指向 `<module>/interface.zig`；import 必须是单行字面量。只有 `kernel` 可以导入构建期 `config` 模块。
- 禁止 `std.Io`、`std.fs`、`std.process`、`std.Thread`、`std.heap`、`std.os`、`std.posix`、`std.net`、`std.debug`、`std.log`、`std.time`。需要这些能力时实现内核自己的 HAL/日志/panic。
- 所有分配显式传入 allocator；IRQ 上下文和热路径零分配；内核堆有上限、可统计。
- 用户指针不可信，只能经过 `copy_from_user`/`copy_to_user`。
- 可恢复错误使用 error union；panic 只用于不变量破坏。禁止 `catch unreachable` 或静默吞掉外部输入错误。
- SMP 正确性是默认；单核只是测试配置；禁止 BKL。
- 禁止全局可变状态；per-CPU 和 boot 后只读数据是仅有的例外，必须写明生命周期与同步方式。
- 关闭 runtime safety 需要基准证据和 ADR。
- 禁止通过放宽 `check_deps` 规则、删除测试、改用 `@setRuntimeSafety(false)` 或把违规 import 藏进 comptime 来绕过约束。规则本身要改，先写 ADR。

## 验证

每次改动至少运行：

```sh
zig fmt --check .
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
zig build check-deps
zig build kernel
zig build qemu-smoke
zig build bench
```

默认构建是 ReleaseSafe；Debug 必须显式 `-Doptimize=Debug`。`zig build qemu-smoke` 需要本机 QEMU + OVMF；脚本会按固定版本/哈希下载 Limine，并用 `-cpu max` 启动正常、panic、exception、nmi、timer、mem、irq、smp、sched、object、user、blk 十二个变体，每个变体各跑 `smp=1` 与 `smp=4`。验证 Debug 和 ReleaseSafe 两套：`zig build qemu-smoke -Doptimize=Debug` 和 `zig build qemu-smoke`。`zig build bench` 在 QEMU `-icount` 下跑确定性基准并与入仓基线比较（5% 回归阈值，基线属 ReleaseSafe；刷新用 `BENCH_UPDATE=1`）。M3 起增加 fuzz smoke。

测试要求见 [ENGINEERING 第 3 节](docs/ENGINEERING.md#3-测试)：纯逻辑必须有 host 单测；硬件路径必须有 QEMU 集成测试或可复现的手动验证；bug 修复先有失败测试。覆盖率是 host 代码的地板（80%），不要写无断言的“调用一下”测试。

未运行或未通过的验证不能写成“已验证”。

## 提交

- 格式：`<type>(<scope>)!?: <summary>`。type 只能是 `feat`、`fix`、`test`、`refactor`、`perf`、`docs`、`build`、`ci`、`chore`、`revert`；scope 使用模块名（`mm`、`arch`……）或区域名（`docs(charter)`、`build(zig)`）。完整规则见 [ENGINEERING 第 4 节](docs/ENGINEERING.md#4-提交)。
- 正文必须有 `Why:` 和 `Verification:`；验证写实际执行过的命令与结果，未执行的内容不能写。
- `feat` 带测试；`fix` 带回归测试（先观察失败，再修复，二者同一提交）；`perf` 带基准数据；`build(zig)` 升级带 ADR 和全矩阵。
- 一个提交一个逻辑变更；重构与行为变更分开；每个提交可构建、可测、可独立回滚。
- 主分支保持线性，使用 rebase/squash；禁止 `wip`/`tmp`/`update` 这类标题。
- 架构、依赖图、工具链、性能/安全取舍、非目标变更先写 ADR。
- 不提交缓存、二进制、ISO、密钥、调试输出或注释掉的代码。
- 验证通过后按用户既有约定提交并推送；强推或历史改写必须先确认。

## 文件地图

- [docs/CHARTER.md](docs/CHARTER.md) — 宪法：定位、v1 范围、非目标、红线、修订程序。
- [docs/ENGINEERING.md](docs/ENGINEERING.md) — Zig/OS 规则、测试、提交格式、评审清单。
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — 模块职责、依赖 DAG、接口边界、启动路径。
- [docs/adr/](docs/adr/) — 架构决策记录；[ADR-0001](docs/adr/0001-kernel-shape-and-v1-scope.md) 定形态，[ADR-0002](docs/adr/0002-m0-boot-chain.md) 定 M0 启动链，[ADR-0003](docs/adr/0003-m1-fatal-exception-entry.md) 定 M1 致命异常入口，[ADR-0004](docs/adr/0004-m1-gdt-tss-ist.md) 定 GDT/TSS/IST，[ADR-0005](docs/adr/0005-m1-apic-timer-irq.md) 定 x2APIC timer/IRQ，[ADR-0006](docs/adr/0006-m1-frame-allocator-and-paging.md) 定帧分配/页表映射，[ADR-0007](docs/adr/0007-m1-kernel-heap-and-demand-paging.md) 定内核堆/按需分页，[ADR-0008](docs/adr/0008-m1-ioapic-external-irq.md) 定 IOAPIC/外部 IRQ，[ADR-0009](docs/adr/0009-m1-benchmark-harness.md) 定基准设施，[ADR-0010](docs/adr/0010-m2-smp-percpu.md) 定 SMP 启动与 per-CPU，[ADR-0011](docs/adr/0011-m2-spinlocks-allocator.md) 定自旋锁与分配器加锁，[ADR-0012](docs/adr/0012-m2-scheduler-core.md) 定抢占调度器核心与 IPI，[ADR-0013](docs/adr/0013-m2-sleep-wake.md) 定睡眠/唤醒与等待队列，[ADR-0014](docs/adr/0014-m2-objects-and-handles.md) 定对象与句柄，[ADR-0015](docs/adr/0015-m2-syscall-user-mode.md) 定 syscall 与用户态，[ADR-0016](docs/adr/0016-m2-tlb-shootdown.md) 定 TLB shootdown，[ADR-0017](docs/adr/0017-m2-heap-stats-syscall-handles.md) 定堆统计与 syscall 句柄，[ADR-0018](docs/adr/0018-m2-thread-stacks-guard.md) 定每线程内核栈与 guard page，[ADR-0019](docs/adr/0019-m3-vfs-initramfs.md) 定只读 VFS 与 initramfs，[ADR-0020](docs/adr/0020-m3-virtio-blk.md) 定 virtio-blk。
- [boot/limine.conf](boot/limine.conf) — Limine 启动配置（M0）。
- [tests/qemu-env.sh](tests/qemu-env.sh) — QEMU/OVMF/Limine 的公共测试环境。
- [tests/qemu-smoke.sh](tests/qemu-smoke.sh) — OVMF + vvfat + Limine 的十二变体 smoke。
- [tests/qemu-bench.sh](tests/qemu-bench.sh) / [tests/bench-baseline.txt](tests/bench-baseline.txt) — icount 基准与 5% 回归基线。
- [tools/check_deps.zig](tools/check_deps.zig) — 依赖与 import 规则的执行者。
- [.gitmessage](.gitmessage) — 提交消息模板；用 `git config commit.template .gitmessage` 启用。
- [build.zig](build.zig) / [build.zig.zon](build.zig.zon) — 构建入口，Zig 0.17.0。
- [initramfs/](initramfs/) — 打包进只读镜像的文件；[tools/mkinitramfs.zig](tools/mkinitramfs.zig) — 打包器（模块入口在仓库根 `mkinitramfs.zig`）。
- `src/` — 内核源码；`tests/` — QEMU 集成测试；`deps/` — smoke 下载的 Limine（gitignored）。
