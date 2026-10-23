# ADR-0014：M2 对象与句柄

- 状态：已接受
- 日期：2026-10-23
- 关系：ADR-0013 的下一增量；为 syscall 与用户态提供句柄边界。

## 背景

内核需要一种统一方式把资源（线程、文件、端点）暴露给调用方，同时不泄漏裸指针、能检查权限、能安全回收。宪章要求“对象/句柄模型为未来把服务迁到用户态保留边界”。

## 决策

1. **对象头**：`Object{ kind, refs(atomic), destroy }`，嵌入具体对象结构；引用计数 acquire/release，归零时调用 destroy。引用计数是唯一生命周期判据。
2. **句柄编码**：u64 = `generation << 32 | index`，纯函数（`object/encoding.zig`）并带 host 单测；表槽位复用时 generation 递增，旧句柄自然失效。
3. **句柄表**：固定容量 64（M2 起步，可调），每项 `{object, generation, rights, occupied}`，`arch.Lock` 保护；`insert` 取引用，`remove` 释放引用（锁外执行 destroy，避免在表锁内跑回调）。查找同时校验“槽位、generation、权限掩码”。
4. **权限**：read/write/manage 位；`lookup(handle, required)` 要求所需位齐全，缺失返回空。
5. **Smoke**：`kernel-object` 变体（退出 65，失败 67）在 BSP 上做单线程自检：插入/查找/权限拒绝、两个句柄的引用计数、remove 后旧句柄失效、destroy 恰好在归零时调用一次、槽位复用后旧句柄失效、表满拒绝。
6. **限制**：对象种类目前只有冒烟用的 `kind_test`（真实种类随所有者增量加入）；无跨表共享/全局对象注册表；无用户态拷贝（syscall 增量）；句柄表无统计接口。

## 后果

- syscall 层可以直接以 u64 句柄为参数，权限与生命周期检查在 object 模块内完成。
- 句柄表锁序：表锁独立，不与分配器/调度器锁嵌套；destroy 回调在锁外，允许回调取其它锁。
- 下一增量：syscall 与用户态入口，随后用真实对象种类（thread、file）替换测试种类。

## 被否决的选项

- **裸指针作句柄**：泄漏地址、无法检测悬垂。
- **无 generation 的索引**：槽位复用后旧句柄会指向新对象。
- **引用计数归零时在表锁内 destroy**：回调可能取锁，扩大锁序。
