# ADR-0022：M3 fuzz 门禁

- 状态：已接受
- 日期：2026-10-24
- 关系：ENGINEERING §3 的测试三层；ADR-0019 的 initramfs、ADR-0021 的 syscall/用户态。

## 背景

工程规则要求 M3 起把 fuzz 纳入门禁（`zig build fuzz`，覆盖 syscall 参数与文件系统镜像），但 M3 前三个增量只交付了 host 单测与 QEMU 矩阵。收尾审计把这一层补齐，否则 M3 不能关闭。

## 决策

1. **Host 变异 fuzz（`zig build fuzz`）**：新增 host 工具，以固定种子（xoshiro256）对 initramfs 镜像做确定性变异（位翻转、字节替换、长度字段破坏、截断/扩展），跑 20 万轮。不变量：解析器不得 panic 或越界；`find` 返回的切片必须落在输入镜像内；`valid` 为真的镜像可安全遍历。ReleaseSafe 构建，让边界错误直接失败。
2. **In-guest syscall fuzz**：shell 增加 `sysfuzz` 命令，用固定种子的 xorshift 生成 syscall 号与参数（非法句柄、0/4096/4097 长度、越界/未映射指针、未知 syscall 号），确保内核只返回错误而不 panic；随机阶段后追加确定性边界断言（超长 write、空路径、控制台 close 等）。shell smoke 执行 `sysfuzz` 并断言 `sysfuzz ok`。
3. **CI**：`check` job 增加 `zig build fuzz`（两个平台，确定性、毫秒级）；`qemu-smoke` 的 shell 变体覆盖 syscall fuzz（Linux）。两者都失败即不进入主分支。
4. **范围**：不做覆盖率引导、不引入外部 fuzz 工具、不加随机时钟/IO；固定种子保证可复现。ELF 加载器与 v2 的网络解析器将来各自补 campaign。

## 后果

- 新增仓库根 `fuzz.zig`（模块入口）与 `tools/fuzz.zig`；shell 多一个测试命令，产品行为不变。
- fuzz 是确定性回归门禁，不是渗透测试；发现的新语义边界必须转成固定用例。

## 被否决的选项

- **只在 nightly 跑外部 fuzzer**：不可复现，且本仓库没有外部依赖预算。
- **把随机性放进 QEMU 矩阵**：会让失败不可复现；in-guest fuzz 用固定种子。
- **推迟到 v1 之后**：宪章 §8 与 ENGINEERING §3 明确 M3 起生效。
