# 架构

状态：v1 草案。依赖图是强制的；模块内部设计随里程碑和 ADR 演进。

## 1. 形态

模块化宏内核：

- 单一内核地址空间，模块之间靠依赖方向和接口隔离，而不是靠地址空间隔离。
- 模块间单向依赖，依赖图是无环的。
- 驱动只依赖 HAL 接口；上层不直接依赖具体驱动。
- 功能按 comptime 裁剪；v1 不动态加载模块。
- `kernel` 是组合根，负责初始化和把实现接到接口上，不复制上层策略。

“可扩展”指新增模块、替换实现、裁剪功能时不需要改一堆无关代码；它不指运行时热插拔。

## 2. 目录与模块

```
src/
  main.zig          kernel 组合根 / 启动入口
  kernel/           kernel 模块内部：初始化顺序、syscall 分发、panic
  lib/              freestanding 基础设施，无项目内依赖
  hal/              硬件抽象接口，只依赖 lib
  arch/             x86_64 实现：GDT/IDT、上下文切换、页表原语、APIC、SMP
  mm/               物理页、地址空间、页表、内核堆、copy_from_user
  object/           对象与句柄、生命周期、权限
  sched/            线程、per-CPU 运行队列、抢占、时钟、IPI、等待队列
  fs/               VFS、initramfs、块缓存、文件对象
  net/              网络栈（v2）
  drivers/          virtio-blk、virtio-net、console 等具体驱动
tests/              QEMU 集成测试与测试夹具（不属于内核依赖图）
tools/              host 工具，如 check_deps
docs/adr/           架构决策记录
```

## 3. 依赖图

| 模块 | 目录 | 允许导入的模块 |
| --- | --- | --- |
| `lib` | `src/lib/` | 无（仅 std 白名单） |
| `hal` | `src/hal/` | `lib` |
| `arch` | `src/arch/` | `lib`, `hal` |
| `mm` | `src/mm/` | `lib`, `hal`, `arch` |
| `object` | `src/object/` | `lib`, `hal`, `arch`, `mm` |
| `sched` | `src/sched/` | `lib`, `hal`, `arch`, `mm`, `object` |
| `fs` | `src/fs/` | `lib`, `hal`, `arch`, `mm`, `object`, `sched` |
| `net` | `src/net/` | `lib`, `hal`, `arch`, `mm`, `object`, `sched` |
| `drivers` | `src/drivers/` | `lib`, `hal`, `arch`, `mm`, `object`, `sched` |
| `kernel` | `src/main.zig`, `src/kernel/` | 所有模块 |

规则：

- 每个模块只通过 `src/<module>/interface.zig` 对外暴露能力。跨模块 import 必须指向该文件；导入模块内部文件是构建失败。
- 模块内部文件可以自由互相导入。
- 禁止反向依赖和环。`fs`/`net`/`drivers` 可以通过 `sched` 阻塞等待，但 `sched` 不能反过来依赖它们。
- 具体驱动实现 `hal` 中的接口；`fs`/`net` 只依赖接口，由 `kernel` 在初始化时注入。
- `tests/` 可以导入任意接口，不受内核依赖图限制；`tools/` 是 host 代码，不进入内核构建。
- `tools/check_deps.zig` 是依赖图的执行者；本表与它必须一致。修改依赖图需要 ADR，并同时更新两者。

## 4. 模块职责

- **lib**：无项目依赖的基础设施。固定容量容器、checked arithmetic、位图、侵入式链表、无分配格式化等。只允许 std 白名单。
- **hal**：纯接口。CPU、IRQ 控制器、时钟、MMIO、DMA、块设备、网络设备、控制台。只有类型和函数表，没有实现、没有策略。
- **arch**：x86_64 具体实现。GDT/IDT、syscall 入口、上下文切换、页表原语、APIC/x2APIC、TSC/HPET、MSR、SMP AP 启动。实现 `hal` 的 CPU/中断/时钟接口。
- **mm**：物理帧分配、地址空间、页表管理、内核堆、guard page、`copy_from_user`/`copy_to_user`。页表策略在这里，寄存器操作在 `arch`。
- **object**：对象头、句柄表、引用/生命周期、权限检查。不拥有线程和等待队列。
- **sched**：线程对象、per-CPU 运行队列、抢占与上下文切换、时钟、IPI、等待队列。文件系统、网络和驱动的阻塞路径经由这里的接口。
- **fs**：VFS 接口、initramfs、块缓存、文件/目录对象。块设备通过 `hal` 的块设备接口访问，不直接 import 具体驱动。
- **net**：v2。包缓冲、ARP/IPv4/ICMP/UDP；传输层通过 `hal` 的网络设备接口访问驱动。
- **drivers**：具体设备。M3 先做 virtio-blk；v2 做 virtio-net。驱动只实现 `hal` 接口，不把设备细节泄漏给上层。
- **kernel**：组合根。启动顺序、feature 裁剪、接口注入、syscall 分发、panic。它不实现 `mm`/`sched`/`fs` 的策略。

## 5. 关键约束

- **SMP-first**：per-CPU 数据、显式锁、无 BKL。单核只是测试配置。
- **接口所有权**：`interface.zig` 是模块唯一的公开面；内部类型不跨模块暴露。需要跨模块传递的不透明句柄用 `object` 的句柄，而不是裸指针。
- **分配**：所有分配显式传入 allocator；模块不持有隐藏的全局堆。`kernel` 在启动时创建内核堆并注入需要的子系统。
- **错误**：模块间接口使用 error union；panic 只用于不变量破坏。
- **feature 裁剪**：`net` 等可选模块由构建选项启用；`kernel` 负责只在启用时接线。关闭的模块不能留下悬挂 import。
- **可移植性**：`arch` 之外的模块不直接操作 x86_64 寄存器、MSR 或端口；这些只能出现在 `arch`/`drivers` 的审计代码中。

## 6. 启动与调用路径（v1）

```
Limine (UEFI)
  -> src/main.zig
  -> arch early init (GDT/IDT, CPU features, serial)
  -> mm (HHDM, frame allocator, kernel address space, heap)
  -> sched (per-CPU, timer, idle thread)
  -> hal 接口绑定 (console, block)
  -> drivers (virtio-blk)
  -> fs (initramfs, VFS)
  -> object + syscall 分发
  -> 用户态 init / shell
```

具体内存布局、初始化顺序和错误恢复策略在 M0/M1 的 ADR 中固定，不在本文档里提前写死。

## 7. 变更流程

- 新增模块：ADR 说明职责、依赖边、接口和测试策略；更新本表与 `check_deps.zig`。
- 修改接口：ADR 或提交说明调用方迁移；跨模块接口变更不能只改一个模块。
- 新增外部依赖：先过宪法第 10 条；内核不得引入外部包。
- 本文档与 `check_deps.zig` 冲突时，以 `check_deps.zig` 的实际行为为准，但必须立即修正文档或代码，二者不允许长期不一致。
