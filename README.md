# OS

一个用 Zig 编写的模块化宏内核，第一目标平台是 QEMU/virt 上的 x86_64。

当前状态：pre-M0。已落地项目宪法、工程规范、依赖检查器和 CI；内核代码从 M0 开始。

## 文档

- [AGENTS.md](AGENTS.md) — AI 代理入口：读文档顺序、硬约束、验证与提交纪律
- [CHARTER](docs/CHARTER.md) — 项目宪法：定位、v1 范围、非目标、红线、修订程序
- [提交规范](docs/ENGINEERING.md#4-提交) — `<type>(<scope>): <summary>`、Why/Verification、ADR 规则；模板见 [.gitmessage](.gitmessage)
- [ENGINEERING](docs/ENGINEERING.md) — Zig/OS 代码规则、测试策略、提交与评审纪律
- [ARCHITECTURE](docs/ARCHITECTURE.md) — 模块依赖图、接口边界、启动路径
- [ADR-0001](docs/adr/0001-kernel-shape-and-v1-scope.md) — 宏内核与 v1 范围的决策记录

## 工具链

- Zig 0.17.0（CI 固定；升级走 ADR）
- QEMU（M0 起需要）
- Linux 或 Windows 主机均可构建 host 检查；QEMU smoke 在 Linux CI 运行

## 本地检查

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build check-deps
zig fmt --check .
```

`zig build` 默认运行 `check-deps` 和 `test`。

`check-deps` 强制模块依赖 DAG、跨模块 `interface.zig` 边界、字面量 import、禁用 std 命名空间。`src/` 目前为空；检查器在 M0 起开始覆盖真实内核代码。

## 目录

```
build.zig / build.zig.zon   构建入口，Zig 0.17.0
src/                        内核源码（M0 起）
tools/check_deps.zig        依赖与 import 规则检查器
docs/                       宪法、规范、架构、ADR
tests/                      QEMU 集成测试（M0 起）
```
