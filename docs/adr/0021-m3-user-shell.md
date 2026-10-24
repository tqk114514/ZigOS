# ADR-0021：M3 用户态 shell 与文件 syscall

- 状态：已接受
- 日期：2026-10-24
- 关系：ADR-0015 的 syscall/用户态、ADR-0019 的只读 VFS、ADR-0020 的 virtio-blk。

## 背景

M3 的验收物是用户态 shell，把只读 VFS 暴露给 ring3 程序。现有 ring3 代码是 smoke 用的手写机器码，只够打印固定字符串；文件访问、控制台输入和可维护的用户程序都需要新的 ABI 与装载方式。

## 决策

1. **用户程序用 Zig 编译**：`user/shell.zig` 是一个独立的 freestanding 可执行文件，链接脚本固定在 `0x40_0000`，按段 W^X，作为 Limine 模块 `shell.elf` 交付。内核实现最小 ELF64 加载器：只接受 `ET_EXEC` 与 `PT_LOAD`，要求段页对齐、文件范围合法、拒绝可写且可执行段；不支持动态链接、解释器、重定位。
2. **启动 ABI**：进入 ring3 时 `%rsp` 指向 `StartupInfo { console: u64, reserved: u64 }`，通用寄存器清零；程序从 `(%rsp)` 取控制台句柄。后续启动参数只在这个结构里扩展。
3. **syscall 扩展**：新增 `open(3)`、`read(4)`、`close(5)`；`write(1)`、`exit(0)`、`yield(2)` 不变。`open` 以原样路径查 VFS（镜像内键均为绝对路径），长度 ≤64；`read` 对控制台句柄读 COM1 输入，对文件句柄读 VFS 数据；`close` 释放句柄。
4. **句柄**：控制台句柄授予 read|write。文件对象为 kind 3，状态来自固定 8 槽静态池（syscall 热路径不分配）；`open` 取槽，`close` 经对象销毁归还；`read` 先 lookup 再 acquire，避免与 close 竞争。句柄表仍为内核全局，每进程表留待后续。
5. **控制台输入**：在 syscall 上下文轮询 COM1 LSR（中断此时被 FMASK 屏蔽），阻塞到至少一个字节，单次最多 64 字节；不引入 IRQ 驱动的 TTY。
6. **shell 功能**：`help`、`cat <path>`、`exit`；提示符 `shell> `；回显输入、处理退格、错误文本。文件来自 initramfs；virtio-blk 尚无可写文件系统，不在此增量挂载。
7. **验证**：新增 `kernel-shell` 变体（退出 77，失败 79）。QEMU 以 `-serial stdio` 把脚本化 stdin 喂给 COM1（`cat /etc/motd`、`cat /hello.txt`、`cat /missing`、`exit`），断言提示符、motd/txt 内容、错误文本与 `SHELL OK`，Debug/ReleaseSafe × smp=1/4。

## 后果

- 用户程序告别手写机器码；ELF 加载器成为后续用户程序的入口。
- 只读文件路径打通到用户态。写路径、管道、作业控制、每进程句柄表仍属后续里程碑。
- COM1 阻塞读期间不响应抢占；shell 是单线程演示，可接受。

## 被否决的选项

- **继续手写机器码 shell**：解析与回显无可维护性。
- **扁平二进制 + 固定段边界**：需要自定义头，且 `.data`/`.bss` 的 W^X 边界不可靠。
- **引入 IRQ TTY、管道或进程表**：超出 M3 范围。

## 附记（2026-10-24 审计）

- COM1 读改为有界轮询：超时返回 0，shell 重试，满足“硬件等待有超时”。
- shell 增加固定种子的 `sysfuzz` 命令，覆盖非法 syscall 参数；测试策略见 ADR-0022。
- 已知遗留：句柄表仍是内核全局；virtio 完成仍为轮询。地址空间与代码/栈帧的回收已由 [ADR-0023](0023-address-space-reclaim.md) 关闭；其余交给 v1 之后的进程与设备工作，不阻塞 M3 验收。
