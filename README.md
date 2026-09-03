# Monster Hunter Rise Mods

《怪物猎人：崛起》REFramework Lua Mod 集合。太刀和弓箭保持为两个独立 Mod，源码与动作分析资料分开维护。

## 已验证环境

- 游戏版本：16.0.2.0
- REFramework TDB：71
- 武器类型：太刀（2）
- 太刀动作库：Bank 100
- 单人任务和多人任务均已完成基础回归测试

## 功能

- 自动居合：仅使用原版动作，攻击来源位于角色正面 120 度范围内才触发。
- 自动见切：仅从原版允许见切的太刀动作触发。
- 竖直攻击兼容：头部落下、脚底上挑等主要由垂直方向构成的攻击按中性水平角处理。
- 手动居合判定延长：延长同一次居合的成功判定，不重复释放动作。
- 手动见切判定延长：修改原版 `PlayerFsm2ActionSeeThroughAttack._EndFrame`，不重复释放见切斩。
- 联机兼容：自动检测多人任务，并过滤队友及非怪物攻击来源。
- 中文设置与运行状态界面。
- 设置自动保存。

自动居合和自动见切默认关闭，由玩家在游戏内自行开启。联机兼容和自动检测多人任务默认开启。

## 默认参数

| 设置 | 默认值 |
| --- | ---: |
| 正面判定总角度 | 120 度（左右各 60 度） |
| 居合提前输入 | 6 帧 |
| 居合延后判定 | 16 帧 |
| 见切提前输入 | 6 帧 |
| 见切延后判定 | 12 帧 |
| 自动见切成功分支延迟 | 2 帧 |

原版见切成功窗口结束边界约为第 30 帧。默认延长 12 帧后，结束边界为第 42 帧。

## 安装

1. 安装适用于当前游戏版本的 REFramework。
2. 将仓库中的 `reframework` 目录复制到游戏根目录。
3. 启动游戏，在 REFramework 的 Script Generated UI 中打开“太刀辅助”。

本仓库不包含 REFramework、游戏文件、联机补丁、存档或第三方 DLL。

## 弓箭辅助（BowAssist）

弓箭源码位于 [`BowAssist/reframework/autorun/BowAssist.lua`](BowAssist/reframework/autorun/BowAssist.lua)。当前基线为运行时武器类型 `13`、Bank `100`，手动闪身箭斩方向 Motion `202/203/204/205`，四向 NodeIndex `4281-4284`，已确认 Action `9234/9287/9251/9269`。

- 自动 GP：进入原版闪身箭斩节点，自动功能默认关闭。
- 手动闪身箭斩判定延长：修改同一次动作的 `_EndFrame`，不重复释放动作，默认延后 `12` Motion 帧。
- 联机兼容和多人任务检测默认开启，过滤队友及非怪物攻击来源。
- 中文 REFramework Script Generated UI、状态诊断和采集 JSON。

弓箭的安装说明和参数见 [`BowAssist/README.md`](BowAssist/README.md)；四向 Action、Act10、Motion FSM 原始资源和采集记录见 [`analysis/bow`](analysis/bow/BOW_ACTION_ANALYSIS.md)。

## 开发与动作拆解资料

后续版本适配所需的太刀 `motfsm2`/`rcol`、弓 `motlist`/`motbank` 原始动作资源，以及运行时节点拆解 JSON，保存在 [`analysis`](analysis/README.md) 目录。该目录仅用于分析和维护，不属于安装内容。

开发过程中验证过的 Motion FSM、Action/Node 索引、DamageReflex 判定、Hook、联机过滤和部署注意事项，记录在 [`analysis/MOD_DEVELOPMENT_NOTES.md`](analysis/MOD_DEVELOPMENT_NOTES.md)。

## 验证状态

- 自动居合：通过
- 自动见切：通过
- 手动居合延长：通过，动作只释放一次
- 手动见切延长：通过，延长窗口内显示“手动见切延长判定”
- 正面攻击：通过
- 背向攻击：不触发
- 站立状态自动见切：不触发
- 多人任务：自动居合、自动见切和手动判定延长通过
- 竖直来源攻击：已加入垂直方向兼容处理

## 注意事项

- 独立 ImGui 窗口尚未加入，当前界面位于 REFramework 菜单内。
- 动作替换类 Mod，尤其是太刀 `motbank/motlist`，可能改变动作帧和视觉表现，建议在排查判定问题时临时停用。
- 使用 Launcher/OnlineFix 时，若启动阶段切走游戏焦点，部分 D3D12/覆盖层组合可能出现启动异常；进入标题画面前保持游戏窗口聚焦。

本次同步只包含源码、动作分析资料和开发记录，不新增任何 Mod 安装包或发布 ZIP；安装包由需要发布时再单独上传。
