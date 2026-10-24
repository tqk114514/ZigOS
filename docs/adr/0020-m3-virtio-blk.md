# ADR-0020：M3 virtio-blk（分两步）

- 状态：已接受
- 日期：2026-10-24
- 关系：ADR-0019 的承载设备；M3 的块设备增量。

## 背景

initramfs 只读镜像由 Limine 交付，M3 还需要真实的块设备路径。virtio-blk 是 QEMU/virt 上的标准块设备；宪章要求现代接口（PCIe ECAM、virtio 1.0、MMIO BAR），不接受 legacy I/O 端口与 MSI 之外的老路径。

## 决策

1. **分两步**：A——设备发现（MCFG→ECAM 映射、PCI 配置空间枚举、找到 virtio-block、解析现代 virtio 能力、映射 BAR）；B——virtqueue 初始化与扇区读取（HAL 块设备接口、smoke 读取并与 Limine 模块镜像比对）。
2. **ECAM**：从 ACPI MCFG 读取 ECAM 基址与总线范围（不硬编码）；用 MMIO 窗口按 1 MiB/总线映射需要扫描的总线（起步只扫 0–1），配置空间按 `bus<<20 | dev<<15 | fn<<12 | off` 访问。
3. **设备匹配**：vendor 0x1AF4，device 0x1001（transitional）或 0x1042（modern-only）；只接受带现代 virtio PCI 能力（cap id 0x09）的设备，拒绝 legacy-only 路径。
4. **能力与 BAR**：遍历能力链取 common/notify/device 三块的 BAR 与偏移，按 BAR 类型（64 位或 32 位、MMIO）映射；BAR 通过 arch 的 MMIO 窗口以 uncached 方式映射。
5. **HAL**：`hal/interface.zig` 增加纯接口 `BlockDevice{ ctx, read_fn(ctx, lba, buf) bool, sector_size }`；`drivers` 实现之，上层只依赖接口。
6. **验证**：新 `kernel-blk` 变体（退出 73，失败 75）；smoke 以 `-drive if=virtio` 附加一个 4 KiB 的 raw 磁盘（内容为打包的 initramfs 镜像），A 步要求 common/notify/device 三类现代能力齐全且 BAR 映射成功，打印设备位置作证据，B 步读取 0 号扇区并与模块镜像前缀比对。
7. **M3 范围限制**：轮询完成（暂不接 MSI/INTx）、单队列、队列深度 16、无写路径、无分区表；每项在后续增量扩展。

## 后果

- `drivers` 首次进入启动路径；virtio 队列内存用独立帧（描述符表/ avail / used 各有物理地址字段），不需要连续分配器。
- 后续真实磁盘与 shell 的 `read` 可以直接建立在 BlockDevice 上。

## 被否决的选项

- **legacy virtio-pci I/O BAR**：宪章禁用落后接口。
- **硬编码 0xB0000000 ECAM 基址**：不同机器不同，MCFG 解析成本低。
- **一次做完队列与写路径**：增量纪律；先让发现与能力解析有独立证据。
