# ADR-0011：M2 自旋锁与分配器加锁

- 状态：已接受
- 日期：2026-10-23
- 关系：ADR-0010 的下一增量。

## 背景

SMP 已能启动全部 CPU，但物理帧分配器与内核堆仍是单核假设的全局状态：任意两个 CPU 同时分配会竞争 bitmap 与 free list，计数会漂移，甚至同一帧被发两次。中断上下文（#PF handler）也会分配帧，所以锁必须自带 IRQ 语义，否则同 CPU 上的中断重入会自死锁。

## 决策

1. **IRQ 安全自旋锁**（`arch/spinlock.zig`）：test-and-test-and-set（先读、再 `cmpxchgWeak(.acquire)` 抢占），失败路径 `pause` 自旋；acquire 保存并关闭本地中断，release 以 `.release` 存储释放并恢复中断状态。不提供“不关中断”的变体，避免调用方选错语义。持锁期间不睡眠、不触发页错误以外的阻塞路径。
2. **锁序**（记入 ARCHITECTURE §5）：`heap → frame`（写堆块头可能触发缺页，handler 取帧锁）；`paging → frame`（建表时分配帧，M2.3 引入）；`paging` 与 `heap` 不嵌套；禁止反向。本增量实现 heap 与 frame 两层。
3. **帧分配器**：单个全局锁保护 bitmap、hint 与计数；`freeCount`/`totalCount` 也取锁，调用点不得已持有该锁。
4. **内核堆**：`Heap` 持锁，`alloc`/`free` 全程持锁；按需分页的缺页发生在锁内，但只经 `heap → frame` 取帧锁，符合锁序。
5. **并发证据**：`kernel-smp` 变体在全部 CPU online 后，BSP 在释放 AP 之前把压力作业写进各 `mp_info.extra_argument`；4 个 CPU 同时各做 8000 次 alloc/free 帧，完成后要求帧计数与开跑前精确一致、无错误，且在 rdtsc 截止时间内。
6. **Smoke 矩阵**：脚本对八个变体各跑 `smp=1` 与 `smp=4`，落实 ENGINEERING 3.1 的启动矩阵（Debug/ReleaseSafe 两套）。
7. **限制**：页表与 TLB 仍无锁（AP 只停放，不会并发改页表）；堆锁内 first-fit 最坏 O(n) 未处理；per-CPU 帧缓存与 TLB shootdown 随调度器/IPI 增量落地。基准基线因锁开销刷新，按 ADR-0009 程序单独提交。

## 后果

- 分配器可以在任意 CPU 与中断上下文安全调用；IRQ 恢复与原子性由全部 smoke 与 4 核并发压力覆盖。
- 未争用时每次 alloc/free 多一次 `cli`/`sti` 与原子操作，基准会如实显示，作为将来 per-CPU 缓存的依据。
- 下一增量：调度器与 IPI，并补页表锁、TLB shootdown 与 `smp=4` 抢占测试。

## 被否决的选项

- **BKL**：宪章禁止。
- **现在做 per-CPU 帧缓存**：先让共享路径正确并量化锁成本，再决定是否值得。
- **无锁 bitmap（CAS 循环）**：复杂度高、正确性难证；先用锁。
- **只给 alloc 加锁、free 不加**：计数与 bitmap 同样会被破坏。