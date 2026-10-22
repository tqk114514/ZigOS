# ADR-0007：M1 内核堆与按需分页

- 状态：已接受
- 日期：2026-10-23
- 关系：ADR-0006 的下一增量。

## 背景

帧分配和页表映射已可用。内核堆需要一个显式 allocator；按需分页需要一个可返回的 #PF handler，而当前 vector 14 走的是致命异常路径。

## 决策

1. **堆范围**：`0xffff_a000_0000_0000` 起 256MiB；块头 `Block{ size, next }`，16 字节对齐；first-fit free list，不合并；bump 指针；`free` 把块放回 free list。页初始不映射。
2. **按需分页**：#PF stub（vector 14）保存 caller-saved 寄存器，调用 `pageFaultHandler(frame) -> bool`：返回 true 则恢复并 `iretq` 重试，返回 false 走现有 `exceptionHandler` 致命路径。handler 只处理 heap 范围内且 error code present=0 的 fault：分配帧并 `mapPage(RW|NX)`；其他 fault 保持致命，避免掩盖 bug。
3. **计数**：`demand_faults` 计数；smoke 断言大于 0。
4. **Smoke**：扩展 `kernel-mem`：帧/HHDM/map 测试后，heap alloc → 写读 → free → 同尺寸 alloc 复用同一指针 → 8192 字节多页写首尾 → `translate`/demand 计数校验；`MEM OK` / 退出 45。
5. **M1 限制**：堆页不解映射、不合并、无配额/统计（除 demand 计数）、无 SMP TLB shootdown、FPU/XMM 状态仍不保存。

## 后果

- 内核堆和按需分页可用；M2 需要 coalescing、统计、guard page，以及调度器需要的可睡眠分配路径。
- #PF handler 只认 heap 范围；其他内核缺页仍然致命。
- 下一增量：IOAPIC/外部 IRQ 与 MMIO 映射，然后 M1 收尾和内存压力测试。

## 被否决的选项

- **立即映射整个堆**：测不到按需分页，启动开销也大。
- **使用 std heap**：隐藏分配和全局状态，违反工程规则。
- **slab/buddy**：M1 不需要；有测量后再换。