# ADR-0012：M2 调度器核心与 IPI

- 状态：已接受
- 日期：2026-10-23
- 关系：ADR-0010/0011 的下一增量。

## 背景

SMP 与锁已就绪，但 AP 只是停放；没有线程、没有抢占、没有核间唤醒。M2 的调度器需要：线程对象、per-CPU 运行队列、上下文切换、定时抢占，以及把线程投递到远端 CPU 的能力（IPI）。

## 决策

1. **线程与栈固定容量**：静态线程池（16 个，每个 16 KiB 栈）；无分配、无睡眠唤醒（下一增量）。线程上下文只保存 callee-saved（rbp/rbx/r12–r15）与 rsp，切换点是普通函数调用与中断退出。
2. **per-CPU 运行队列**：每 CPU 一个环形队列 + 自旋锁（复用 ADR-0011 的 IRQ 安全锁）；每 CPU 有一个不入队的 idle 线程。当前线程记录在 per-CPU 结构里，仅本 CPU 在关中断或持锁时读写。
3. **抢占**：timer IRQ（vector 32）经注册的向量处理器进入调度器：EOI、扣 quantum、到期置 `need_resched`。IRQ 公共出口在 `iretq` 之前调用注册的抢占钩子，钩子在 IF=0 下选择下一个线程并 `switchTo`。新线程经自己的 trampoline 启动并先开中断。线程持锁时 IF=0，因此不会被抢占——与 ADR-0011 的锁语义一致。
4. **IPI**：远端 CPU 的新线程入队后用 x2APIC ICR 发送 vector 50 IPI；处理器只做 EOI + 置 `need_resched`，实际切换发生在 IRQ 出口。IPI 复用 `irq_common`。
5. **分层**：调度器放在新 `sched` 模块（ARCHITECTURE 的 DAG 允许其依赖 arch）。arch 不依赖 sched；kernel 组合根注册 timer/IPI 向量处理器、抢占钩子与 AP 入口（`setVectorHandler`/`setPreemptHook`/`setApHandler`），并在 sched 变体里启动 AP 调度器。注册发生在任何中断使能之前，注册后只读。
6. **Smoke**：`kernel-sched` 变体（退出 61，失败 63）：BSP 启动 AP 调度器并等待 ready，然后给每个 CPU 投递 2 个纯计算 worker（无 yield，只有抢占能让出）；控制器线程等待全部 worker 达到目标计数，校验每个 CPU 的切换次数 > 0、线程计数达标，打印每 CPU 切换数与每线程计数。
7. **限制**：无睡眠/阻塞/优先级/工作窃取/线程回收（done 线程继续以 hlt 占位）；用户态抢占在 syscall/用户态增量；per-CPU TSS/IST、页表锁、TLB shootdown 仍待办。

## 后果

- 内核线程可以在任意 CPU 上被定时抢占，AP 不再停放而是运行 idle/worker。
- 抢占只在 IRQ 出口发生，调度决策不嵌套锁（只取本 CPU 队列锁），锁序不新增边。
- 下一增量：睡眠/唤醒与等待队列，随后对象/句柄、syscall 与用户态抢占。

## 被否决的选项

- **协作式调度（yield）**：宪章要求可抢占，测试线程故意不 yield。
- **全局 runqueue**：与 SMP-first/per-CPU 方向冲突。
- **动态分配线程/栈**：调度路径零分配；固定池先行。
- **arch 直接调用 sched**：违反依赖 DAG；用组合根注册钩子。