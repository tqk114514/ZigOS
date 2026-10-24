# ADR-0019：M3 VFS/initramfs 起步

- 状态：已接受
- 日期：2026-10-24
- 关系：M2 收官后的第一个 M3 增量。

## 背景

M3 需要 VFS、只读 initramfs、virtio-blk 与用户态 shell。当前没有任何文件抽象；shell 的第一步是能列出/读取只读文件。块设备与 shell 依赖更多子系统，先建立最小但正确的 VFS 边界。

## 决策

1. **模块**：新建 `fs` 模块（DAG 允许依赖 lib/hal/arch/mm/object/sched）。本增量只含 `interface.zig`（VFS 对外 API）与 `initramfs.zig`（只读内存镜像）。
2. **initramfs 格式**：自包含平面归档：magic `ZRAM`，随后若干 `u16 name_len, name, u32 data_len, data`，`name_len == 0` 结束。解析是**零分配**的顺序扫描（`find(image, name)`），越界/截断一律返回 null。
3. **VFS 范围（起步）**：平面命名空间（路径即完整键，含前导 `/`），`open(path) !File`、`read(file, buf) -> n`（EOF 返回 0）、`size(file)`。目录树、句柄化文件对象与权限随 shell/virtio 增量扩展。
4. **镜像来源**：本增量用编译期构造的演示镜像（`initramfs.demo`，含文本/空文件），让解析与读取都有 host 单测；**构建期打包真实 initramfs 产物**放到 virtio-blk 增量（需要与块设备读取、构建工具一起设计）。
5. **验证**：纯逻辑用 host 单测（`fs/vfs_test.zig`）：查找成功/缺失/坏 magic/截断、部分读/EOF、空文件；不新增 QEMU 变体（未进入启动路径），现有矩阵继续跑防回归。

## 后果

- `fs` 首次进入依赖图；后续 shell 的 `read` syscall 直接接 `fs/interface.zig`。
- 平面命名空间是明确的 M3 起步限制，目录与路径规范化在真实镜像增量再引入。

## 被否决的选项

- **先写 tar/cpio 解析**：需要构建期打包与更多错误面，推迟到镜像产物增量。
- **KVFS 直接暴露镜像字节**：把格式泄漏给上层，VFS 边界应从第一天存在。
- **为 VFS 引入动态分配**：镜像只读且体积固定，顺序扫描足够。
