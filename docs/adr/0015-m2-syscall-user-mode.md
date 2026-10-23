# ADR-0015：M2 syscall 与用户态

- 状态：已接受
- 日期：2026-10-23
- 关系：ADR-0014 的下一增量；M2 的最后一块。

## 背景

对象/句柄已经可用，但所有代码都在 ring0。M2 要求 syscall 与用户态：独立的用户地址空间、受控的进入/返回路径、不可信指针边界、以及“用户态可被抢占”的证明。这同时必须补齐 M1 起挂账的每 CPU TSS 与页表锁。

## 决策

1. **GDT 重排**：`0 空 / 1 内核代码 0x08 / 2 内核数据 0x10 / 3 用户数据 0x18 / 4 用户代码 0x20 / 5.. 每 CPU TSS（0x28 + 16·i）`。用户数据在低地址、用户代码紧邻其后，满足 SYSRET 对 CS/SS 选择器顺序的要求（STAR：SYSCALL 进入用内核 CS，SYSRET 返回用“用户数据、用户代码”）。TSS 改为每 CPU 独立结构（rsp0 指向该 CPU 的内核栈、IST 栈也按 CPU 分配），`gdt.load()` 按 CPU 取自己的 TSS 选择器。
2. **进入/返回**：`syscall`/`sysretq`（EFER.SCE、STAR、LSTAR、FMASK：返回时屏蔽 IF/TF/DF 由 FMASK 控制，进入后立即 `cli`）。入口先 `swapgs` 取得 per-CPU 块与内核栈，保存用户上下文（通用寄存器 + RCX/R11），再进入 C 分派；返回时恢复上下文、`swapgs`、`sysretq`。内核态 GS base 与用户态 GS base 分开存放在 `percpu`（swapgs 使用 IA32_KERNEL_GS_BASE）。
3. **用户地址空间**：每个用户进程一张 PML4；内核半区（HHDM、内核镜像、MMIO 窗口）与内核共享只读映射，用户半区按需映射 4 KiB 页并执行 W^X（NX 数据、无写+执行）。页表变更持**全局 paging 锁**（锁序 `paging → frame`），并登记到待 shootdown 集合；跨核更新后发送 TLB shootdown IPI（vector 51），目标 CPU 执行 `invlpg`/CR3 重载后应答。切换进程用 CR3 写入。
4. **不可信指针**：所有用户指针只经 `copy_from_user`/`copy_to_user`：校验区间不越过用户地址上限、逐页检查用户映射可读/可写、失败返回 error union，不 panic。
5. **syscall ABI**（自定义，无 POSIX）：`rax` 编号、`rdi/rsi/rdx` 参数、`rax` 返回；句柄是 u64，权限在 object 层检查。首批：`exit(status)`、`write(handle, buf, len)`（仅串口句柄）、`yield()` 用于让出。
6. **Smoke**：新 `kernel-user` 变体（退出 69，失败 71）：内嵌一个最小用户程序 ELF 镜像，验证 (a) `write` 输出 `USER OK`；(b) `copy_from_user` 拒绝非法指针（高地址/未映射/只读）；(c) 用户计算线程可被定时抢占（计时器计数推进）；(d) `exit` 终止进程并回到内核收尾。矩阵保持 smp=1/4 × Debug/ReleaseSafe。
7. **限制**：单进程/单用户线程起步（多进程与 fork 风格创建后续）；无信号/文件系统；用户 GS base 留给 TLS 后续；seccomp/审计不做。

## 后果

- 用户态首次成为可运行形态，syscall 边界与句柄模型闭合；W^X 与 copy_from/to_user 成为后续所有用户接口的硬约束。
- 每 CPU TSS/IST 与 paging 锁、TLB shootdown 一并补齐，M2 的架构欠账清空。
- 之后进入 M3：VFS、只读 initramfs、virtio-blk、用户态 shell。

## 被否决的选项

- **`int 0x80` 风格**：可用但不现代；`syscall` 是 x86_64 的标准路径。
- **单地址空间（用户与内核同 PML4）**：无法做 W^X 与隔离，宪章要求用户指针不可信。
- **在 syscall 路径分配内存**：热路径零分配原则；参数校验与拷贝用固定栈缓冲。
- **无 TLB shootdown 的映射更新**：SMP 下会读到旧映射，正确性不可接受。

## M2 收尾状态（2026-10-23）

- (a) write 输出、ring3 取指/返回、CR3 切换：(d) exit 回内核：已落地并经 QEMU smoke 验证（`kernel-user` 退出 69）。
- (b) copy_from_user 拒绝非法指针：已落地并验证。
- (c) 用户态定时抢占：**未完成**。已实现 IRQ/PF/致命存根的条件 swapgs 与 `enterUser` 的关中断窗口修复；把用户程序改为长跑并接入调度器后，在抢占路径上出现内核态致命 #PF（RIP 位于 `percpu.current` 的 `%gs:0`，CR2=0），尚未定位。当前用户模式以 IF=0 运行，smoke 只覆盖非抢占的 ring3 路径。
- TLB shootdown：未实现；当前单用户线程、映射在进入用户态前建立，paging 锁保证一致性。多进程/多用户线程增量落地时必须补齐。
