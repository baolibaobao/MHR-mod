# 开发工具源码

这里保存本次动作定位与采集使用的最小源码：

- `LongSwordKamuiCapture.lua`：神威居合 `Motion 161 -> 162` 前后帧、节点、Action、Condition 和 Transition 采集。
- `bow-fsm-extract/`：按已确认条目提取弓 `Bow.motfsm2.43` 的一次性工具。
- `pak-extract/`：按 PAK、输出路径及资源哈希定向提取的通用命令行工具。

两个 C# 工具使用 .NET 10 和 `Zstandard.Net 1.1.7`。仓库只保留项目文件、
NuGet 配置和源码，构建时产生的 `bin/`、`obj/` 不提交。`bow-fsm-extract` 中的路径
与哈希属于当前游戏版本的可复现记录；适配新版本时应先更新目标 PAK 和资源哈希。

通用提取器参数：

```text
PakExtract PAK OUTPUT LOWER_HASH UPPER_HASH
```
