# OS

一个用 Zig 编写的模块化宏内核，第一目标平台是 QEMU/virt 上的 x86_64。

当前状态：M1 进行中。M0 已完成；IDT、GDT/TSS/IST 和正常/panic/exception/nmi QEMU smoke 已落地。APIC 时钟和内存管理尚未开始。

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
```

`zig build` 默认运行 `check-deps`、host tests，并构建 ReleaseSafe kernel。Debug 必须显式 `-Doptimize=Debug`。

`zig build qemu-smoke` 需要 QEMU + OVMF；默认跑 ReleaseSafe，`-Doptimize=Debug` 跑 Debug 变体。脚本会下载 Limine，然后启动正常、panic、exception、nmi 四个变体。Windows 本地可设 `QEMU_ACCEL=whpx`，默认 TCG。

`check-deps` 强制模块依赖 DAG、跨模块 `interface.zig` 边界、字面量 import、禁用 std 命名空间，以及只有 `kernel` 可以导入构建期 `config`。

## 目录

```
build.zig / build.zig.zon   构建入口，Zig 0.17.0
boot/limine.conf            Limine 启动配置
src/                        内核源码
tests/qemu-smoke.sh         OVMF + vvfat + Limine 的正常/panic/exception/nmi smoke
tools/check_deps.zig        依赖与 import 规则检查器
docs/                       宪法、规范、架构、ADR
deps/                       smoke 下载的 Limine（gitignored）
```
