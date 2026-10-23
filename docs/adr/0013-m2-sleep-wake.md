# ADR-0013：M2 睡眠/唤醒与等待队列

- 状态：已接受
- 日期：2026-10-23
- 关系：ADR-0012 的下一增量。

## 背景

调度器只会轮转纯计算线程；任何需要等待的路径（定时、对象、I/O、系统调用）都需要让出 CPU 并在事件到来时被唤醒，且唤醒可能来自另一个 CPU。没有这个原语，后续的 object/syscall 无法构建。

## 决策

1. **线程状态**：`free/runnable/running/blocked`；运行队列持有 runnable，current 是 running，睡眠表与等待队列持有 blocked。
2. **定时睡眠**：`sleepTicks(n)` 以全局单调 tick 计数（定时器处理器原子递增）计算唤醒点，把当前线程放进全局睡眠表后切换到下一线程/idle。每个 CPU 的定时器处理器在递增 tick 后扫描到期睡眠者，经 `makeRunnable` 放回其 home CPU 的运行队列；跨 CPU 时发送 vector 50 IPI。
3. **等待队列**：`WaitQueue{lock, waiters[], count}`；`wait()` 在关中断下登记当前线程并阻塞，`wakeOne()` 弹出首个等待者并唤醒（其余唤醒原语后续再加）。等待没有内置超时；需要超时的调用方使用 `sleepTicks` 或后续的组合原语。
4. **阻塞期间的切换**：`blockCurrent` 在 IF=0 下选下一个线程并 `switchTo`；线程被唤醒后从 `switchTo` 返回，恢复自己保存的中断状态，`sleepTicks`/`wait` 的调用方继续执行。语义与 IRQ 出口抢占一致。
5. **锁序**：`sleep/wq → per-CPU queue`，禁止反向；睡眠/等待路径不嵌套分配器锁（调度器零分配）。
6. **Smoke**：`kernel-sched` 在 worker 阶段之后追加三线程：sleeper 睡 2 tick 并校验 `woke_at ≥ 2`；waiter 在 `WaitQueue` 上阻塞；waker 睡 2 tick 后 `wakeOne`。控制器等待全部完成，输出 `SCHED: sleep ok` / `SCHED: wake ok`。
7. **限制**：无超时等待、无优先级/公平性、无线程回收（完成线程以 hlt 占位）、无用户态阻塞。

## 后果

- 内核第一次具备“让出 CPU 并跨核恢复”的原语；对象/句柄与 syscall 的阻塞路径可以建立在它之上。
- 唤醒路径在定时器 IRQ 内执行，只取睡眠/队列锁并发 IPI，不做分配。
- 下一增量：对象/句柄，之后 syscall 与用户态（含用户态抢占、页表锁与 TLB shootdown）。

## 被否决的选项

- **忙等代替睡眠**：浪费 CPU，且无法证明阻塞/唤醒路径。
- **每 CPU 睡眠表**：跨核到期扫描更复杂；全局表 + 锁在本规模更简单。
- **在等待队列里内建超时**：先保持原语最小，组合超时等真实需求出现再做。
