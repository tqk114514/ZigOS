# ADR-0004：M1 GDT、TSS 与 IST

- 状态：已接受
- 日期：2026-10-23
- 决策者：项目作者
- 关系：扩展 ADR-0003；ADR-0003 中“gate 使用当前 CS、IST=0”的部分由本 ADR 取代。

## 背景

ADR-0003 的 IDT 依赖 Limine 的 GDT 和当前内核栈。普通异常可以打印，但没有自己的 TSS/IST；double fault、NMI、machine check 在坏栈上不保证能诊断。M1 下一个增量需要自己的段表和专用异常栈。

## 决策

1. **GDT**：null、内核 code `0x08`、内核 data `0x10`、TSS descriptor `0x18`/`0x20`。DPL0；M1 不建立 user segments。
2. **TSS**：用 104 字节显式数组按 x86_64 偏移填充（`rsp0` 在 offset 4，IST1/2/3 在 36/44/52，`iomap_base` 在 102）；Zig 的 packed struct 不能包含数组，显式字节布局更可审计。`rsp0` 指向 64KiB 内核栈顶；IST1/2/3 分别指向 16KiB 的 double-fault/NMI/machine-check 栈；`iomap_base = 104`（无 I/O bitmap）。
3. **加载**：汇编 trampoline 执行 `lgdt` → `ltr` → 重载 DS/ES/SS/FS/GS → push 新 CS + `lretq` 远返回，切换到 `0x08`。不使用编译器生成的 CS 切换。
4. **IDT**：gate selector 使用 `0x08`；vector 2/8/18 分别使用 IST2/1/3，其他异常 IST0。NMI handler 读取当前 RSP 并检查是否落在 IST2 范围内，打印 `ist: ok`；NMI 退出码 39，其他致命异常退出码 37。
5. **Smoke**：新增 `kernel-nmi` 变体执行 `int $2`；QEMU smoke 期待 `EXCEPTION 2: non-maskable interrupt`、`ist: ok`、退出码 39。普通 `int3` 变体还应显示 `cs: 0008`，证明 GDT 已切换。Debug 和 ReleaseSafe 都跑。
6. **配置**：`config.nmi_smoke` 仍是只有 `kernel` 可以导入的构建期开关。

## 后果

- 普通异常继续使用 64KiB 内核栈；NMI/DF/MC 使用独立的 16KiB IST 栈，异常期间的栈污染不会互相影响。
- 还没有 user segments、ring3、I/O bitmap；`rsp0` 已为 M2 预留。
- double-fault gate/IST 已配置，但没有故障注入测试；NMI smoke 覆盖同一套 IST 机制。
- 下一步是 APIC/IOAPIC/timer，然后是物理页/虚拟内存/内核堆。

## 被否决的选项

- **继续使用 Limine GDT**：没有 IST，selector 依赖 bootloader，不适合 M1 的异常模型。
- **NMI/DF/MC 共用一个 IST 栈**：一个栈损坏会同时毁掉这三种最高优先级异常。
- **在汇编里手写 TSS 布局**：Zig packed struct 更容易审计字段和偏移。
