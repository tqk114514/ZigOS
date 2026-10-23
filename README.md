# OS

一个用 Zig 编写的模块化宏内核，第一目标平台是 QEMU/virt 上的 x86_64。

当前状态：M2 进行中。M1 已完成（含内存压力测试与性能基准设施）；SMP 启动/per-CPU、IRQ 安全自旋锁与分配器加锁、抢占式调度器核心与 IPI、睡眠/唤醒与等待队列、对象/句柄核心、用户地址空间与 copy_from_user/copy_to_user、syscall 入口、ring3 用户程序与用户态定时抢占已落地。M2 收尾遗留（ADR-0015 记录）：TLB shootdown 与多进程推迟到下一增量。

## 文档

- [AGENTS.md](AGENTS.md) — AI 代理入口：读文档顺序、硬约束、验证与提交纪律
- [CHARTER](docs/CHARTER.md) — 项目宪法：定位、v1 范围、非目标、红线、修订程序
- [提交规范](docs/ENGINEERING.md#4-提交) — `<type>(<scope>): <summary>`、Why/Verification、ADR 规则；模板见 [.gitmessage](.gitmessage)
- [ENGINEERING](docs/ENGINEERING.md) — Zig/OS 代码规则、测试策略、提交与评审纪律
- [ARCHITECTURE](docs/ARCHITECTURE.md) — 模块依赖图、接口边界、启动路径
- [ADR-0001](docs/adr/0001-kernel-shape-and-v1-scope.md) — 宏内核与 v1 范围的决策记录
- [ADR-0002](docs/adr/0002-m0-boot-chain.md) — M0 启动链、镜像布局与 QEMU smoke
- [ADR-0003](docs/adr/0003-m1-fatal-exception-entry.md) — M1 致命异常入口与 exception smoke
- [ADR-0004](docs/adr/0004-m1-gdt-tss-ist.md) — GDT/TSS/IST 与 NMI smoke
- [ADR-0005](docs/adr/0005-m1-apic-timer-irq.md) — x2APIC timer 与可返回 IRQ 入口
- [ADR-0006](docs/adr/0006-m1-frame-allocator-and-paging.md) — 物理帧分配与 4/5-level 页表映射
- [ADR-0007](docs/adr/0007-m1-kernel-heap-and-demand-paging.md) — 内核堆与按需分页
- [ADR-0008](docs/adr/0008-m1-ioapic-external-irq.md) — IOAPIC、外部 IRQ 与 MMIO 映射
- [ADR-0009](docs/adr/0009-m1-benchmark-harness.md) — 性能基准设施（icount 与 5% 回归基线）
- [ADR-0010](docs/adr/0010-m2-smp-percpu.md) — SMP 启动与 per-CPU 基础设施
- [ADR-0011](docs/adr/0011-m2-spinlocks-allocator.md) — 自旋锁与分配器加锁
- [ADR-0012](docs/adr/0012-m2-scheduler-core.md) — 抢占式调度器核心与 IPI
- [ADR-0013](docs/adr/0013-m2-sleep-wake.md) — 睡眠/唤醒与等待队列
- [ADR-0014](docs/adr/0014-m2-objects-and-handles.md) — 对象与句柄
- [ADR-0015](docs/adr/0015-m2-syscall-user-mode.md) — syscall 与用户态

## 工具链

- Zig 0.17.0（CI 固定；升级走 ADR）
- QEMU + OVMF（M0 起；Windows 使用 QEMU 自带的 edk2 firmware）
- Limine v12.9.4 由 [tests/qemu-smoke.sh](tests/qemu-smoke.sh) 按固定哈希下载到 `deps/`（不提交）
- Linux/Windows 都能做 host 检查和交叉编译；QEMU smoke 在 Linux CI 运行，Windows 本地也可运行

## 本地检查

```sh
zig fmt --check .
zig build test -Doptimize=Debug
zig build test -Doptimize=ReleaseSafe
zig build check-deps
zig build kernel
zig build kernel -Doptimize=Debug
zig build qemu-smoke
zig build qemu-smoke -Doptimize=Debug
zig build bench
```

`zig build` 默认运行 `check-deps`、host tests，并构建 ReleaseSafe kernel。Debug 必须显式 `-Doptimize=Debug`。

`zig build qemu-smoke` 需要 QEMU + OVMF；默认跑 ReleaseSafe，`-Doptimize=Debug` 跑 Debug 变体。脚本会下载 Limine，并使用 `-cpu max` 启动正常、panic、exception、nmi、timer、mem、irq、smp、sched、object、user 十一个变体，每个变体各跑 `smp=1` 与 `smp=4`；mem 变体覆盖帧分配、页表映射、内核堆、按需分页和帧/堆耗尽压力测试（x2APIC timer 需要该 CPU 模型）。Windows 本地可设 `QEMU_ACCEL=whpx`，默认 TCG。

`zig build bench` 在 QEMU `-icount shift=7,sleep=off` 下运行确定性基准（帧分配、堆分配、按需分页），与 [tests/bench-baseline.txt](tests/bench-baseline.txt) 比较，慢 5% 以上即失败。基线属 ReleaseSafe 与当时的 QEMU 版本；刷新用 `BENCH_UPDATE=1 bash tests/qemu-bench.sh` 并单独提交。

`check-deps` 强制模块依赖 DAG、跨模块 `interface.zig` 边界、字面量 import、禁用 std 命名空间，以及只有 `kernel` 可以导入构建期 `config`。

## 目录

```
build.zig / build.zig.zon   构建入口，Zig 0.17.0
boot/limine.conf            Limine 启动配置
src/                        内核源码
tests/qemu-env.sh           QEMU/OVMF/Limine 的公共测试环境
tests/qemu-smoke.sh         OVMF + vvfat + Limine 的十一变体 smoke
tests/qemu-bench.sh          icount 基准与 5% 回归门禁
tests/bench-baseline.txt    基准基线（ReleaseSafe）
tools/check_deps.zig        依赖与 import 规则检查器
docs/                       宪法、规范、架构、ADR
deps/                       smoke 下载的 Limine（gitignored）
```
