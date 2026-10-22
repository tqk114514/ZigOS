# ADR-0003：M1 致命异常入口

- 状态：已接受
- 日期：2026-10-23
- 决策者：项目作者

## 背景

M0 已经通过 naked `_start` 进入 `kmain`，使用 64KiB 静态内核栈。M1 需要 IDT、异常诊断、之后的中断/时钟和内存管理。第一个增量只解决“CPU 异常发生时能打印现场并停止”，不实现异常恢复或 IRQ 返回路径。

## 决策

1. **IDT**：256 个 entry；0–31 号异常使用汇编 stub。其余 entry 暂不 present；中断仍关闭，等 APIC/IOAPIC 阶段再填。
2. **Gate**：0x8E（present、DPL0、64-bit interrupt gate），selector 在运行时读取当前 CS（Limine 的 GDT），IST=0。M1 下一增量再建立自己的 GDT/TSS 和 double-fault/NMI 的 IST 栈。
3. **Stub 布局**：无错误码的异常 push 0 作为 dummy error，再 push vector；有错误码的异常只 push vector（CPU 已经压入 error code）。`isr_common` 把 RSP 作为 `ExceptionFrame *` 传给 Zig handler，然后对齐栈调用 C ABI。
4. **Handler**：致命、noreturn。打印 vector、名称、error code、RIP/CS/RFLAGS/RSP/SS，随后 QEMU test exit（写 `0x12`，退出码 37），真机 halt。这里不保存通用寄存器、不 `iretq`，因为第一个增量不恢复故障上下文。
5. **Smoke**：构建第三个 kernel 变体（`kernel-exception`），`config.exception_smoke=true` 时执行 `int3`。QEMU smoke 期待 `EXCEPTION 3: breakpoint`、RIP 行和退出码 37；正常/panic 变体保持不变。Debug 和 ReleaseSafe 都跑。
6. **配置**：`config.exception_smoke` 仍是只有 `kernel` 可以导入的构建期开关；`check-deps` 强制。

## 后果

- M1 早期就能看到 CPU 异常现场，而不是 triple fault。
- 在建立 IST 之前，若异常发生时栈本身已损坏（例如 double fault），handler 不一定能打印；这是下一增量的首要工作。
- 当前只处理致命异常；IRQ 需要完整寄存器保存/恢复和 `iretq`，将在 APIC/timer 增量中单独设计。
- 后续 M1 增量顺序：GDT/TSS/IST → APIC/IOAPIC/timer → 物理页/虚拟内存 → 内核堆/按需分页。

## 被否决的选项

- **现在就做完整 IRQ common stub**：没有 IRQ 消费者，寄存器保存/恢复和 `iretq` 会引入未测试的复杂度。
- **复用 panic handler**：异常需要打印 CPU frame（RIP/CS/RFLAGS/RSP/SS），panic handler 没有这些信息。
- **32 个 Zig naked 函数**：汇编宏和一张 stub 表更直接，也更容易审计。
