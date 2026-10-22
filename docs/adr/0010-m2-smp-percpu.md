# ADR-0010：M2 SMP 启动与 per-CPU 基础设施

- 状态：已接受
- 日期：2026-10-23
- 关系：M2 的第一个增量；后续的锁、调度、IPI 都以此为基础。

## 背景

M1 单核假设：全局状态无锁、没有 per-CPU 数据、核间通信为零。M2 要求 SMP、preemptive 调度和用户态，第一步必须让所有 CPU 真正跑起来，并给每个 CPU 一个可寻址的本地数据块（migrate 无关的当前 CPU 标识、后续的运行队列与 IPI 状态）。当前没有 AP 启动代码，也没有任何跨核同步设施。

## 决策

1. **AP 启动用 Limine MP 协议**，不用自写 INIT-SIPI 实模式 trampoline（需要 16 位代码、无页表、固定物理地址，且现有 boot 链不提供这些）。请求置 `LIMINE_MP_REQUEST_X86_64_X2APIC` 标志，保证 bootloader 保留 x2APIC（否则它会在“固件已启用 x2APIC”时尝试回退，破坏我们的 MSR 时钟/EOI）。
2. **启动时序**：BSP 走既有 `_start` 路径；AP 由 Limine 启停，在 bootloader 提供的栈上等待。BSP 完成串口、GDT/TSS、IDT 构建后，按下述发布顺序逐个唤醒。
3. **唤醒协议**：先写好 AP 交付所需的一切（表已构建、`percpu` 数组已初始化），再对每个 AP 的 `goto_address` 做 release 原子写；AP 端以 acquire 观察后跳转。入口是裸函数：`cli`、开 SSE（CR0/CR4，与 BSP 相同）后 `call apMain`，RDI（mp_info 指针）原样传递，再进 Zig。AP 随后加载 BSP 已建好的 GDT/TSS 与 IDT（GDTR/IDTR 是 per-CPU 寄存器），按 mp_info 指针匹配下标，建立自己的 per-CPU 块后 `cli; hlt` 停放。
4. **per-CPU 数据**：静态数组 `[8]Cpu{self, index, apic_id, online}`，GS base（IA32_GS_BASE）指向本 CPU 的块；`current()` 用 `%gs:0` 取 self。静态上限 8 个 CPU，超出部分不唤醒（继续停在 bootloader 里），M2 不引入动态分配。
5. **在线确认**：AP 写 `self/index/apic_id` 后以 release 置 `online=1`；BSP 用 acquire 轮询，等待设 rdtsc 截止时间（4e9 ticks），超时或校验失败即 `SMP FAIL`。BSP 校验每个块的 `self`、`index`、`apic_id` 与 MP 表一致——这同时证明 GS 基址在每个 CPU 上设置正确。
6. **Smoke**：新 `kernel-smp` 变体以 `-smp 4` 启动，输出 `SMP: cpu i apic N` 每核证据与 `SMP OK`，退出 57（失败 59）；脚本额外断言第 3 号 CPU 出现在输出里。其余变体保持 `-smp 1`。
7. **范围与限制**：本增量只把 AP 唤醒并停放，不让它们参与工作；per-CPU TSS/IST、AP 上的中断、IPI、自旋锁、TLB shootdown、把全部 smoke 扩到 `smp=1/4` 矩阵都在后续增量（锁与调度落地时）。AP 当前复用 BSP 的 TSS 与 IST 栈，停放期间关中断，因此不会并发使用它们。

## 后果

- 每个 CPU 有独立的 `Cpu` 块与 GS 基址，`current()` 无需锁；BSP 不依赖“自己是 CPU 0”。
- Limine MP 请求会让 bootloader 在所有变体（包括 `-smp 1`）里处理 AP 停放；单核路径行为不变。
- 释放顺序成为约定：新增任何“AP 启动前必须存在”的全局结构，必须在释放 AP 之前初始化，否则 AP 会看到半初始化状态。
- 下一增量：自旋锁与 IRQ 语义 + 帧分配器/堆加锁，随后把 smoke 扩到 smp=1/4。

## 被否决的选项

- **自写 INIT-SIPI**：需要实模式 trampoline 和固定低地址页面，Limine MP 已提供带栈的等价能力。
- **启动时不给 AP 分配 per-CPU 块、等调度器再说**：调度器和 IPI 全都需要“当前 CPU”标识，先做最小块成本最低。
- **动态分配 per-CPU 数组**：违反“启动期固定容量”的取向；M2 上限 8 个 CPU 足够。
- **AP 启动后进入调度器**：调度器还不存在；停放（cli/hlt）是唯一诚实的中间态。