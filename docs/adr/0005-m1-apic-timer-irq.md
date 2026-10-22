# ADR-0005：M1 APIC timer 与可返回 IRQ 入口

- 状态：已接受
- 日期：2026-10-23
- 决策者：项目作者
- 关系：M1 的 APIC 时钟增量；IOAPIC/外部 IRQ 推迟到内存映射之后。

## 背景

M1 已有 IDT/GDT/TSS/IST，但中断仍关闭。需要 APIC 时钟和一条能保存/恢复上下文并 `iretq` 的 IRQ 路径。外部设备 IRQ 和 IOAPIC 需要显式 MMIO 映射，放到分页/HHDM 增量。

## 决策

1. **M1 timer 只走 x2APIC MSR 路径**：CPUID leaf 1 ECX bit 21 检查 x2APIC；QEMU smoke 使用 `-cpu max`。如果不可用，timer 变体打印 `x2APIC unavailable` 并以退出码 43 结束。xAPIC MMIO/IOAPIC 等有显式 MMIO 映射后再做。
2. **x2APIC 设置**：IA32_APIC_BASE 打开 x2APIC 和 global enable；SVR 使能 APIC，spurious vector 用 `0x2F`（IDT vector 47）；LVT timer 使用 periodic、vector 32；divide 16；initial count `0x100000`。
3. **IRQ 入口**：16 个汇编 stub（vector 32–47），保存 caller-saved 通用寄存器；RBX 暂存原始 RSP；16 字节对齐后调用 C handler；恢复寄存器并 `iretq`。EOI 写 x2APIC MSR `0x80B`。
4. **FPU/XMM**：M1 IRQ 路径不保存 XMM/FPU 状态；timer 变体只中断 idle `hlt` 循环，没有 live FPU state。M2 调度/用户态前必须加 FXSAVE 或保持内核 FPU-free。
5. **IDT**：vector 32–47 填 IRQ gate（0x8E、CS `0x08`、IST0）；spurious vector 47 也在表内。
6. **测试**：`kernel-timer` 变体启动 timer 后进入 `hlt`；handler 第 3 次 tick 打印 `TIMER OK` 并以退出码 41 结束。正常/panic/exception/nmi 四个变体保持不变。

## 后果

- APIC timer 和可返回 IRQ 路径可用；还没有 IOAPIC、外部 IRQ 或 SMP。
- timer count 是 QEMU 相对的固定值，未校准到墙钟；M2 调度前要用 TSC/HPET 校准。
- IRQ 不保存 XMM/FPU；当前测试只中断 idle 循环，安全；M2 必须补齐。
- 下一步：IOAPIC + MMIO 映射（随分页），然后物理页/虚拟内存/内核堆。

## 被否决的选项

- **现在做 xAPIC/IOAPIC MMIO**：LAPIC/IOAPIC 在 RAM HHDM 之外，需要先有显式 MMIO 映射。
- **PIT 校准**：被平台契约禁止。
- **只做 one-shot timer**：periodic 更适合重复 tick smoke；调度器以后再选模式。
