# ADR-0002：M0 启动链与 QEMU 验证

- 状态：已接受
- 日期：2026-10-23
- 决策者：项目作者

## 背景

M0 要落地 UEFI + Limine 启动、串口、panic/backtrace 和 QEMU smoke。开发机是 Windows，没有 xorriso、mtools 或分区工具，也不使用 WSL；ISO/分区工具链不能成为 M0 的前置条件。CI 运行在 Ubuntu。

## 决策

1. **引导**：Limine v12.9.4。使用官方二进制包中的 `BOOTX64.EFI`；固定 `limine-binary.tar.gz` 的 SHA256 为 `847334bc4bc142de996fbd132806b89ed73ac9ab34dbc1e90cfebf1fcc68c2b1`。UEFI 由 QEMU 的 edk2 OVMF pflash（code + vars）提供。
2. **镜像**：内核是高层内核，基址 `0xffffffff80000000`。编译使用 kernel code model、非 PIC、关闭 red zone、保留 frame pointer、关闭 stack probing。M0 使用 Limine 提供的栈；M1 再建立内核栈。Limine 交接时没有启用 SSE；入口设置 CR0/CR4 的 MP/OSFXSR/OSXMMEXCPT，因为编译器可能为普通 16 字节移动生成 SSE 指令。
3. **协议**：请求 Limine base revision 6，只放置 base revision request 和 start/end markers；M0 不请求 framebuffer、HHDM 或内存映射。
4. **串口**：COM1，115200 8N1；所有硬件等待都有上界，超时丢字节而不是死等。
5. **panic**：自定义 panic namespace，不依赖 `std.debug`；串口输出消息和返回地址，再做有界 frame-pointer backtrace；随后触发 QEMU test exit，真机 halt。
6. **测试**：QEMU q35 + OVMF + 用 vvfat 把一个构建目录暴露成 ESP；内核通过 `isa-debug-exit` 的端口 `0xf4` 结束 QEMU。正常启动写 `0x10`（退出码 33），panic 变体写 `0x11`（退出码 35）。panic 变体触发真实越界检查而不是 `@panic`，以覆盖编译器的安全检查路径。smoke 脚本在 `tests/qemu-smoke.sh`，同时检查串口标记和 backtrace；CI 在 Ubuntu 26.04 上跑 Debug 和 ReleaseSafe 两种构建。本地默认 TCG，可用 `QEMU_ACCEL=whpx`。
7. **构建配置**：`kernel` 可以导入构建系统提供的 `config` 模块（目前只有 `panic_smoke`）；其他模块禁止。`zig build check-deps` 强制。
8. **依赖**：Limine 二进制由 smoke 脚本按固定版本和哈希下载到 `deps/`，不提交仓库；OVMF 由本机 QEMU 安装或 CI 的 `ovmf` 包提供。

## 后果

- Windows 上不需要 ISO 或分区工具；ESP 只是一个构建产物目录。
- QEMU smoke 首次运行需要网络下载 Limine；固定哈希保证可复现。
- vvfat 只用于测试，不是生产镜像格式；真实硬件和 ISO 镜像以后再定。
- M0 的 backtrace 依赖 Limine 栈，栈边界检查有限；M1 建立内核栈后收紧。
- 高层内核从第一天生效，避免 M1 再做一次地址空间迁移。

## 被否决的选项

- **ISO + xorriso**：Windows 工具链缺失。
- **HDD 镜像 + limine.exe**：需要分区和 FAT 工具，Windows 上同样缺失；Limine 的 Windows host tool 也不提供 UEFI 安装。
- **自写 UEFI 应用**：偏离 Limine 启动链决策。
- **QEMU `-kernel` multiboot**：不是 UEFI/Limine 路径，和平台契约冲突。
- **BIOS 启动**：与 x86_64/UEFI 平台决策冲突。
