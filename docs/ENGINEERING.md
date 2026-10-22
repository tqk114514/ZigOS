# 工程规范

本文件是 `CHARTER.md` 的操作化版本。它规定代码怎么写、测试做到什么程度、提交长什么样。与宪法冲突时以宪法为准。

规则分为“必须”“禁止”“默认”。违反“必须/禁止”的代码不能合入；偏离“默认”需要在提交或 ADR 中给出理由。

## 1. Zig 规则

### 1.1 分配

- 所有分配必须显式传入 allocator。禁止依赖任何全局或隐藏分配器。
- 内核堆必须有上限、可统计；超过配额的分配返回错误，不得 panic。
- IRQ 上下文禁止分配；热路径禁止分配（见宪法第 7 条）。
- 优先使用固定容量结构。需要动态增长时，先给出上界。

### 1.2 错误与失败

- 可恢复错误使用 error union；禁止用 `panic` 处理用户输入、设备错误或资源耗尽。
- 禁止 `catch unreachable`、`catch {}` 或默认值吞掉外部输入的错误。
- `@intCast` 必须先证明范围，或改用 `std.math.cast`/`std.math.add` 等带检查的转换。
- 每个 `errdefer`/`defer` 的释放路径必须在测试或 QEMU 集成测试中走过一次。

### 1.3 不安全操作

以下操作只允许出现在经过审计的模块（arch、mm 的页表代码、drivers 的 MMIO 路径等），并且必须写 `// SAFETY:` 说明：

- `@ptrCast`、`@ptrFromInt`、`@alignCast`
- inline asm
- `@setRuntimeSafety(false)`
- 直接读写硬件寄存器或物理地址

`SAFETY` 注释必须回答：指针对齐和有效性由谁保证、生命周期多长、并发访问如何同步。没有答案的转换不允许合入。

### 1.4 导入与 std

- `@import` 的参数必须是单行字面量字符串；禁止计算 import。
- 内核模块之间只能导入 `<module>/interface.zig`；模块内部文件可以互相导入。`zig build check-deps` 强制。
- `kernel` 可以导入构建系统提供的 `config` 模块（编译期开关）；其他模块禁止。`check-deps` 强制。
- 只允许 `std`、`builtin` 和项目内 `.zig` 文件；禁止外部包。
- 内核代码只使用 std 的纯计算子集：`std.mem`、`std.math`、`std.atomic`、`std.fmt` 等。
- 禁止 `std.Io`、`std.fs`、`std.process`、`std.Thread`、`std.heap`、`std.os`、`std.posix`、`std.net`、`std.debug`、`std.log`、`std.time`；`check-deps` 扫描。需要这些能力时，写内核自己的 HAL/实现。
- 禁止 libc、动态链接和运行时加载。

### 1.5 状态与并发

- 禁止全局可变状态。per-CPU 数据和 boot 后只读数据是仅有的例外，且必须在模块文档中说明生命周期与同步方式。
- 不使用 async/await 作为内核执行模型。v1 的模型是线程 + 中断 + 显式同步。
- comptime 只用于配置和表生成（IDT、页表布局、feature 裁剪），不用于隐藏控制流或模拟运行时多态。
- 优先静态派发。需要接口时使用 `interface.zig` 中的函数表，并写明调用上下文（IRQ/进程/可睡眠）。

### 1.6 代码形态

- `zig fmt` 是强制的；CI 跑 `zig fmt --check .`。
- 命名遵循 Zig 风格；公开声明有文档注释；注释只解释 why，不解释 what。
- 递归必须有上界；内核栈大小固定；禁止在栈上放大的临时缓冲。
- 禁止注释掉的代码、调试打印、未使用的声明或“以后再接”的半成品。
- 默认 ReleaseSafe；关闭 runtime safety 需要基准证据和 ADR。

## 2. OS 规则

### 2.1 SMP 与锁

- 新代码默认必须在 `smp=4` 下正确；`smp=1` 只是调试配置。
- 自旋锁必须明确 IRQ 语义（是否关中断）；禁止在持锁时睡眠、分配或触发页错误。
- 锁序必须在 `ARCHITECTURE.md` 或模块文档中列出；Debug 构建在加锁点断言锁序。
- 禁止 BKL（大内核锁）和“先单核跑通再补 SMP”的设计。
- 页表、TLB、IPI、per-CPU 数据的更新路径必须有并发测试或 QEMU 压力测试。

### 2.2 内存

- 用户指针不可信。所有跨边界访问走 `copy_from_user`/`copy_to_user`，检查长度、对齐和整数溢出。
- 内核与用户页表执行 W^X；内核栈有 guard page；堆和映射有配额。
- 物理页、虚拟页、句柄、DMA 缓冲区都必须有所有者、生命周期和失败回收路径。
- 禁止在内核态直接解引用用户地址。

### 2.3 中断与时间

- IRQ 上下文不睡眠、不分配、不等待；上半部只做最小工作，延迟工作交给下半部机制（M1 设计）。
- 所有硬件等待有超时；禁止无限自旋。
- 用户态必须可被抢占；调度器不能依赖协作式让出。
- panic 必须输出诊断并停机，不得进入未定义状态；M0 起包含 backtrace。

### 2.4 资源与日志

- 每个资源有配额和统计；句柄表、进程表、映射表都有上限。
- 失败路径释放全部资源；使用 `defer`/`errdefer`，并在测试中覆盖失败路径。
- 日志分级、可按子系统关闭；热路径禁止打印。
- 不使用 `std.debug.print` 作为内核日志。

## 3. 测试

### 3.1 三层

1. **Host 单测**：纯逻辑（mm 数学、分配器、对象表、FS/网络解析器、锁序模拟）。`zig build test`，毫秒级，每次提交都跑。
2. **QEMU 集成**：启动 + 串口断言；`zig build qemu-smoke`（M0 起）。矩阵：`smp=1/4` × `Debug/ReleaseSafe`。每个 PR 都跑。
3. **Fuzz**：syscall 参数、文件系统镜像、网络包（M3 起）。`zig build fuzz` 目标；nightly 或发布前跑。

### 3.2 必须满足

- 新增纯逻辑公开函数：至少一个 host 单测。
- 新增硬件路径：至少一个 QEMU 集成测试，或在提交中记录可复现的手动验证步骤。
- 每个边界至少测试一个失败路径（非法参数、长度溢出、超时、资源耗尽）。
- Bug 修复：先写一个失败的回归测试并在本地观察失败，再修复；测试与修复进入同一提交，保证每个提交都可构建可测。无法在现有层级复现时，添加最接近的复现并记录缺口。
- 调度器、分配器、锁的测试必须是确定性的：固定种子、固定事件序列，不用 sleep 计时。

### 3.3 覆盖率

- 覆盖率是地板，不是目标。M0 选定工具后，host 可测代码行覆盖率下限 80%。
- 覆盖率下降的提交需要说明；内核专属路径以启动矩阵、压力测试和 fuzz 为准，不追求行覆盖率。
- 禁止为了覆盖率写无断言的“调用一下”测试。

### 3.4 CI 门禁

- 每次提交：`zig fmt --check .`、`zig build test`、`zig build test -Doptimize=ReleaseSafe`、`zig build check-deps`。
- 平台矩阵：Linux + Windows（host 检查）。
- M0 起：QEMU smoke（Linux runner）。
- M3 起：fuzz smoke。
- 性能基准在 M0 建立 baseline，之后每次 PR 跑相对回归；阈值默认 5%。

## 4. 提交

提交消息用英文（type/scope/summary/body 保持一致）；文档语言不受此限。主分支保持线性：使用 rebase/squash，不产生 merge commit。

提交模板见根目录 `.gitmessage`，启用：

```sh
git config commit.template .gitmessage
```

### 4.1 格式

```
<type>(<scope>)!?: <summary>

Why:
- <motivation, constraint, or problem>

Verification:
- <command actually run> — <result>

[ADR: docs/adr/NNNN-....md]
[BREAKING CHANGE: <migration>]
```

- `<type>` 只能是 4.2 表中的值。
- `<scope>` 必填，见 4.3。
- `<summary>` 用祈使句、小写开头、不加句号；整个 header 不超过 72 字符。
- `Why:` 必填，写动机、约束或要解决的问题，不写“改了什么”。
- `Verification:` 必填，写实际执行过的命令与结果；未执行的内容不能写。
- 架构、依赖图、工具链、性能/安全取舍、非目标变更必须加 `ADR:` 脚注；ADR 文档本身的提交不需要引用自己。
- 破坏性变更在 scope 后加 `!`，并加 `BREAKING CHANGE:` 脚注写迁移方式。

### 4.2 type

| type | 用途 | 必要条件 |
| --- | --- | --- |
| `feat` | 新行为、新能力 | 测试随提交；架构变化先写 ADR |
| `fix` | 修复 bug | 回归测试随提交；Verification 记录“失败 → 通过” |
| `test` | 只改测试或测试夹具 | 不改变生产行为 |
| `refactor` | 不改行为的结构调整 | 现有测试语义不变 |
| `perf` | 性能改进 | Verification 必须有 before/after 或相对基线数据 |
| `docs` | 只改文档 | 链接/格式检查 |
| `build` | `build.zig`、`build.zig.zon`、工具链、依赖 | Zig 升级需要 ADR 和全矩阵 |
| `ci` | CI 工作流或 CI 脚本 | 在 PR 上验证 |
| `chore` | 仓库维护、格式化、ignore、工具配置 | 无行为变更 |
| `revert` | 回滚提交 | 正文写 `This reverts commit <hash>.` 和原因 |

禁止把 `wip`、`tmp`、`update`、`misc`、`changes`、`fixup`、`squash` 当作 type。格式化为 `chore(fmt)`；安全修复用 `fix(<module>)`，不新增 `security` 类型。

### 4.3 scope

代码类提交（`feat`、`fix`、`test`、`refactor`、`perf`）的 scope 必须是模块名或工具名：

`lib`、`hal`、`arch`、`mm`、`object`、`sched`、`fs`、`net`、`drivers`、`kernel`、`tools`

其他 type 使用受影响区域的小写 kebab-case 名称：

`docs(charter)`、`docs(adr)`、`docs(engineering)`、`build(zig)`、`ci(actions)`、`chore(repo)`、`chore(fmt)`、`revert(<module>)`

约束：

- 一次提交只有一个主要 scope。跨模块接口变更在正文列出所有受影响模块；scope 用接口所有者。
- `kernel` 用于启动、初始化、syscall 分发和组合根；`tools` 用于 host 工具。
- 新增模块或区域需要先更新 `ARCHITECTURE.md` 和 `check_deps.zig`，再使用新 scope。

### 4.4 纪律

- 一个提交一个逻辑变更，一个 type。重构与行为变更分开；需要同时重构和加功能时，先 `refactor`，再 `feat`。
- 每个提交必须能独立构建、通过测试、可回滚；禁止 WIP 提交进入主分支。
- 测试归属：功能的测试随 `feat`；纯覆盖/测试重构用 `test`；bug 回归测试进入 `fix`（先观察失败，再修复，二者同一提交）。
- `perf` 没有基准数据就不是 `perf`，改用 `refactor` 或 `feat`。
- `build(zig)` 升级单独提交，附 ADR 和全矩阵结果，不混入功能改动。
- 行为变更所需的文档更新可以和代码同提交；独立的文档修改用 `docs`。
- 架构、依赖图、工具链、性能/安全取舍、非目标变更必须写 ADR。
- 不提交注释掉的代码、调试输出、生成的二进制、ISO、密钥或本地缓存。
- AI 辅助生成的改动适用同一标准；提交者承担验证责任。

### 4.5 示例

```
feat(mm): add per-CPU frame cache

Why:
- Every frame allocation currently takes the global allocator lock.
- Per-CPU caches remove that contention from the hot path.

Verification:
- zig fmt --check .
- zig build test
- zig build test -Doptimize=ReleaseSafe
- zig build check-deps
- qemu-smoke -smp 4, 10 boot iterations
```

```
fix(arch): mask x2APIC MSR before fallback

Why:
- QEMU without x2APIC faults on the first MSR write during AP bring-up.

Verification:
- regression test failed before the fix (smp=4 boot panic), passes after
- zig fmt --check .
- zig build test
- zig build test -Doptimize=ReleaseSafe
- zig build check-deps
```

```
test(sched): cover preemption at tick boundary

Why:
- The tick path had no test for preempting a thread that just resumed.

Verification:
- zig fmt --check .
- zig build test
- new test fails when the preemption check is removed
```

```
feat!(object): replace handle table ABI

Why:
- The index-based handle table cannot express per-handle rights.

Verification:
- zig fmt --check .
- zig build test
- zig build test -Doptimize=ReleaseSafe
- zig build check-deps
- qemu-smoke -smp 4

BREAKING CHANGE: handles are opaque; callers must use handle_from_index().
ADR: docs/adr/NNNN-opaque-handles.md
```

```
docs(adr): accept modular monolithic kernel

Why:
- Record the kernel-shape decision and rejected alternatives.

Verification:
- local links checked
```

## 5. 评审清单

- [ ] 符合宪法与架构；没有新增未批准的依赖边。
- [ ] 所有分配显式、有界；IRQ/热路径没有分配。
- [ ] 用户输入和外部数据在边界校验；失败路径完整。
- [ ] 锁序、IRQ 语义、SMP 安全性有说明和测试。
- [ ] import 是字面量、跨模块走 `interface.zig`、没有禁用 std 命名空间。
- [ ] 新增/修改行为有测试；bug 修复有失败过的回归测试。
- [ ] `zig fmt --check .`、`zig build test`、`zig build test -Doptimize=ReleaseSafe`、`zig build check-deps` 全绿。
- [ ] 提交原子；消息包含 why 和实际验证。
- [ ] 没有密钥、大二进制或无关文件。
- [ ] 行为或架构变化已同步文档/ADR。

## 6. 例外

例外必须满足三个条件：写明原因、指定负责人、给出失效日期。记录在 ADR 或提交正文中。到期未续期的例外视为违规，相关代码必须删除或修正。

没有记录在案的例外不成立。
