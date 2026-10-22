# ADR-0008：M1 IOAPIC 与外部 IRQ（含 MMIO 映射）

- 状态：已接受
- 日期：2026-10-23
- 关系：ADR-0005（x2APIC timer/IRQ）与 ADR-0006（帧分配/页表映射）的下一增量。

## 背景

中断目前只有 CPU 本地的 x2APIC timer。外部设备中断要经过 IOAPIC：它的寄存器在 RAM 的 HHDM 范围之外的物理空洞里，缓存属性不受 HHDM 控制，必须显式建立 uncached 映射。IOAPIC 基址不能硬编码，应从固件的 ACPI 表发现。

## 决策

1. **MMIO 窗口**：`paging.mmio_window = 0xffff_c000_0000_0000`；`mapMmioPage(phys)` 把物理页 1:1 映射进窗口（virt = window + phys），PTE 置 PCD（uncached）、NX、RW，重复调用幂等。窗口与 HHDM、内核堆、smoke 测试范围不重叠，4/5 级页表下同样有效。
2. **ACPI 发现**：经 Limine RSDP 请求取 RSDP（base revision ≥ 4 返回 HHDM 虚拟地址）；`acpi.load` 校验 RSDP/XSDT/MADT 的校验和，沿 XSDT 找到 MADT（签名 `APIC`），解析第一块 IOAPIC（entry type 1）和 ISA 中断源覆盖 ISO（entry type 2）。表内地址按 ACPI 规范是物理地址，经 HHDM 读取。只实现 ACPI 2.0+ 的 XSDT 路径。解析是纯逻辑，host 单测用合成的表缓冲区。
3. **IOAPIC 驱动**：IOREGSEL(0x00)/IOWIN(0x10) 间接寄存器访问；版本寄存器读出最大重定向项数；`maskAll` 先屏蔽全部条目；`program(gsi, vector, flags, dest)` 按 ISO 的 MPS INTI 极性/触发位编程 fixed 交付与物理目的（x2APIC ID 低 8 位），先写带屏蔽位的低半、再写高半、最后解除屏蔽。
4. **外部 IRQ 交付**：RTC 周期中断（ISA IRQ8）经 GSI8 到 vector 48。vector 48 有独立存根、共用 `irq_common`；`irq_common` 把 vector 传给 C 分派器，分派器用编译期 switch 路由（无全局处理表）。handler 先读 RTC reg C 清挂起位，再 EOI。
5. **Smoke**：新增 `kernel-irq` 变体：帧分配/ACPI/MMIO/IOAPIC/RTC 全部就绪后 sti，收到 8 个 tick 打印 `IRQ OK`，退出码 49（失败 51）；脚本额外断言 `EXT: ioapic base` 与 `EXT: gsi 8 -> vector 48` 两条设置证据。
6. **M1 限制**：单 IOAPIC、固定交付、x2APIC ID < 256、无 MSI、无 PCI INTx 路由协商、不解析 FADT/AML、不接管 8259。

## 后果

- 外部中断路径可用；M2 的 IPI 与设备驱动可以直接挂 vector。handler 注册表等 `sched`/`object` 有所有权模型后再引入。
- MMIO 窗口是通用设施，之后 virtio 等设备的寄存器映射共用它。
- ACPI 解析只覆盖 MADT 所需的最小子集；CPU 拓扑（x2APIC 列表）等 M2 SMP 时再扩展。
- 下一增量：M1 收尾与内存压力测试。

## 被否决的选项

- **硬编码 0xFEC00000**：把 QEMU 配置写进内核；MADT 解析成本低，且 M2 SMP 也需要 ACPI。
- **经 HHDM 直接读写 IOAPIC**：缓存属性不可控，还依赖 Limine 是否恰好映射了该物理空洞。
- **动态 handler 注册表**：全局可变状态，违反工程规则；M1 用编译期分派。
- **PIT/8259 作为中断源**：落后技术，且绕开了本增量要验证的 IOAPIC 路径。