# ADR-0009：M1 性能基准设施

- 状态：已接受
- 日期：2026-10-23
- 关系：落实 CHARTER 第 7 条与 ENGINEERING 3.4 的基准门禁；M0 起挂账，M1 收尾补齐。

## 背景

宪章要求性能由基准证明、QEMU 绝对值不作数、默认 5% 回归阈值；工程规范要求基准进 CI。到目前为止内核只有功能 smoke，没有任何性能回归防线：分配器、按需分页或中断路径的意外 O(n) 或指令膨胀不会被发现。

QEMU/TCG 的墙钟时间受宿主机调度影响，噪声远大于 5%，不能直接当门禁；需要一个在 CI 噪声下仍然确定的度量。

## 决策

1. **确定性来源**：QEMU `-icount shift=7,sleep=off`。icount 下虚拟时钟按已执行的 guest 指令推进，guest TSC 跟随虚拟时钟，因此 TSC 差值是指令工作量的确定函数。实测同一构建两次运行逐周期一致（frame_churn 489882752、heap_churn 38798080、demand_fault 3110528 完全相同）。
2. **测量点**：新 `kernel-bench` 变体（退出码 53，失败 55），跑三个 M1 热路径工作负载并打印 `BENCH <name> <cycles> <ops>`：
   - `frame_churn`：帧分配器稳态分配/释放（2048 轮 × 32 帧）；
   - `heap_churn`：堆小块 alloc/write/free（8192 次，先热身把页映射好）；
   - `demand_fault`：512 KiB 新页首触（按实际 demand 计数计 ops），覆盖 #PF 入口、映射与 iret 重试。
3. **比较与门禁**：`tests/qemu-bench.sh` 计算 cycles/op，与 `tests/bench-baseline.txt` 比较；比基线慢 5% 以上即失败，快 5% 以上提示刷新基线；基线缺条目或多出条目都失败，防止工作负载被悄悄删改。
4. **基线**：入仓文本文件，记录生成时的 QEMU 版本；刷新用 `BENCH_UPDATE=1 bash tests/qemu-bench.sh` 生成并单独提交。基线只对默认 ReleaseSafe 构建成立；Debug 构建数字显著更高（实测 heap_churn +381%），不参与门禁。
5. **接入**：`zig build bench`（依赖 `kernel-bench`）；CI 在 qemu-smoke job 增加 QEMU bench 步骤。Debug 内核仍构建本变体以保编译覆盖，但不跑基准。
6. **范围**：M1 只有这三个热路径；M2 的 syscall/IPI/调度基准随对应增量加入并刷新基线。

## 后果

- 性能回归在 CI 可见：分配器与页错误路径的指令膨胀 ≥5% 会红。
- 数字是 TCG 指令当量的代理，不是真实硬件性能；宪章允许（QEMU 绝对值不作数），阈值只在相对比较内有效。
- QEMU 大版本升级可能改变 icount 记账细节；届时用 `BENCH_UPDATE=1` 刷新基线并单独提交，与工具链升级同等对待。
- 负向对照已执行：压低基线 10% 触发 `regressed beyond the 5% threshold` 失败；基线加入幽灵条目触发 `missing measurement` 失败。

## 被否决的选项

- **墙钟时间**：CI 噪声远大于 5%，门禁会随机红。
- **非 icount 的 TSC**：读数依赖宿主频率，不可复现。
- **QEMU 插件/指令计数工具**：需要额外构建与宿主依赖，收益与 icount 重叠。
- **改善也判失败**：会把有意优化挡在门外；改善只提示刷新基线。