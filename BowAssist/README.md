# BowAssist

弓箭独立 REFramework Lua Mod。`BowAssist.lua` 是当前已部署并完成回归验证的功能版，和太刀 `LongSwordAssist` 保持为两个独立脚本。

## 已验证基线

- 游戏版本：`16.0.2.0`
- REFramework TDB：`71`
- 运行时武器类型：`13`（菜单枚举中的 `PlayerWeaponType.BOW = 10` 不是运行时读数）
- 动作库：`Bank 100`
- 手动闪身箭斩方向 Motion：前/后/左/右为 `202/203/204/205`
- 自动动作执行确认 Motion：`452/456`
- 四向 Motion FSM NodeIndex：`4281-4284`
- 四向已确认 Action：`9234/9287/9251/9269`（前/后/左/右）

完整的方向映射、原始动作资源和采集证据见 [`analysis`](../analysis/README.md) 与 [`analysis/bow/BOW_ACTION_ANALYSIS.md`](../analysis/bow/BOW_ACTION_ANALYSIS.md)。

## 当前功能

- 自动 GP：在伤害流程仍为原版受击时，进入原版闪身箭斩节点；动作执行由游戏原版完成。
- 同一攻击链保护：一次命中在相邻帧重复进入伤害回调时，保护 3 帧内只提交一次入口并拦截重复结算；确认进入 `Motion 452/456` 后才启用周期锁，因此不会在 GP 动作中再次发动。
- 自动闪身箭斩兼容开关：与自动 GP 使用同一原版入口，保留为独立设置以便后续扩展。
- 手动闪身箭斩判定延长：只修改同一次动作的 DamageReflex/Act10 `_EndFrame`，不会再次释放闪身箭斩。
- 联机兼容：默认开启，过滤非主玩家和非怪物攻击；多人同步时攻击对象为空会结合攻击类型判断。
- 自动检测多人任务：显示集会所/任务状态、玩家数和检测来源。
- 中文 REFramework Script Generated UI、状态诊断、采集标记和 JSON 保存。

自动 GP、自动闪身箭斩默认关闭；手动判定延长、联机兼容和多人检测默认开启。界面当前位于 REFramework 菜单内，独立 ImGui 窗口尚未加入。

## 默认参数

| 设置 | 默认值 |
| --- | ---: |
| 手动闪身箭斩延后帧 | 12 Motion 帧 |
| 自动 GP | 关闭 |
| 自动闪身箭斩兼容开关 | 关闭 |
| 手动闪身箭斩判定延长 | 开启 |
| 联机兼容模式 | 开启 |
| 自动检测多人任务 | 开启 |

帧数是 Motion 帧，不是毫秒。关闭判定延长后，原版成功边界恢复；重新载入 Motion FSM 或关闭选项时脚本会恢复缓存的原始 `_EndFrame`。

## 文件

```text
reframework/autorun/BowAssist.lua
reframework/autorun/BowBalance.lua
```

`BowBalance.lua` 是第二个独立弓箭 Mod，负责倍率、耐力、Buff、射程、会心距离和
射击动作速度；它不参与自动 GP。完整参数见 [`BowBalance_README.md`](BowBalance_README.md)。

运行时配置和采集文件由 REFramework 在游戏目录的 `reframework/data/` 中生成：

```text
BowAssist_config.json
BowAssist_capture.json
```

仓库中的采集 JSON 是开发证据，不是用户配置；不要把配置文件覆盖到别人的游戏目录。

## 安装

1. 安装适用于当前游戏版本的 REFramework。
2. 将 `BowAssist/reframework` 目录合并到游戏根目录。
3. 启动游戏，在 REFramework 的 Script Generated UI 中打开“弓箭辅助”。

仓库不包含 REFramework、游戏运行文件、联机补丁、存档、DLL 或安装 ZIP。动作原始文件仅放在 `analysis/raw` 供版本适配，不应复制到游戏目录。
