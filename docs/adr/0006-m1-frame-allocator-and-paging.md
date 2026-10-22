# ADR-0006：M1 物理帧分配与 4/5-level 页表映射

- 状态：已接受
- 日期：2026-10-23
- 关系：M1 内存增量的第一部分；内核堆与按需分页在下一增量。

## 背景

M1 需要物理内存管理和虚拟页映射。Limine 已经提供 HHDM 和物理内存映射；内核继续使用 Limine 建好的 CR3。先建立帧分配器和 map/translate 原语，内核堆和按需分页依赖它们；按需分页还需要一个可返回的 #PF handler，放到下一增量。

## 决策

1. **Limine 请求**：新增 HHDM 和 memmap request；response 为空时 smoke 直接失败。
2. **帧分配器**：静态 128KiB bitmap（1 = used），支持 4GiB / 1M 帧；只把 `LIMINE_MEMMAP_USABLE`（type 0）交给分配器；type 6（executable/modules）和低 1MiB 保留；`allocFrame`/`freeFrame`/计数；物理内存通过 HHDM 访问。暂不支持 4GiB 以上、NUMA 或 zone。
3. **分页**：在当前 CR3 上做 map/translate；读 CR4.LA57 决定从 PML5 还是 PML4 开始；中间表由帧分配器分配并清零；数据页 NX；`invlpg`。暂不拆分 huge page，也没有 SMP TLB shootdown。
4. **Smoke**：`kernel-mem` 验证 memmap/HHDM → 帧 alloc → HHDM 写读 → free → 测试 PML4 slot（`0xffff_9000_0000_0000`）map 到帧 → 虚拟写读 → `translate` 校验；成功打印 `MEM OK` 并退出 45，失败退出 47。QEMU smoke 变为六个变体。

## 后果

- 物理帧分配和页表映射可用；还没有内核堆、按需分页、huge page 拆分或 SMP TLB shootdown。
- 4GiB 上限；QEMU/virt M1 足够，更大内存需要动态 bitmap（ADR）。
- 测试虚拟地址 `0xffff_9000_0000_0000` 保留给 smoke；M2 再正式规划内核地址空间。
- 下一增量：内核堆（显式 allocator、按需映射）＋可返回 #PF 的按需分页＋内存压力测试。

## 被否决的选项

- **现在做 buddy/链表分配器**：bitmap 对 4GiB 足够且可审计；性能优化等 M2 有测量后再做。
- **现在做内核堆/按需分页**：需要先有可返回的 #PF handler；和下一增量一起做。
- **重建完整页表**：继续使用 Limine 的页表，保持 bring-up 风险低。