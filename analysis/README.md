# 太刀动作拆解资料

本目录保存《怪物猎人：崛起》16.0.2.0 的太刀动作分析资产，供后续版本适配和功能维护使用。这些文件不是安装包，不应复制到游戏目录。

## 目录内容

### 原始拆包资源

```text
raw/natives/STM/player/Fsm/LongSword/LongSword.motfsm2.43
raw/natives/STM/player/hit/LongSword.rcol.20
```

- `LongSword.motfsm2.43`：太刀 Motion FSM、节点、Action、Condition 和 Transition 的原始资源。
- `LongSword.rcol.20`：太刀碰撞与攻击判定相关资源。

保留原始游戏路径是为了后续使用 RE_RSZ、010 Editor 或 BHVT 工具时直接定位，不必重新从游戏包中解包。

### 运行时拆解

```text
captures/LongSwordAssist_capture.json
captures/LongSwordAssist_transition_probe_legacy_invalid.json
```

`LongSwordAssist_capture.json` 是有效采集，包含：

- 游戏版本 `16.0.2.0`
- 武器类型 `2`
- 动作库 `Bank 100`
- 48 个动作与受击事件
- 13 个关键节点的 Action、Condition、Transition Event 和父子关系

`LongSwordAssist_transition_probe_legacy_invalid.json` 是历史探针。其静态节点对象均为 `nil`，仅用于记录失败方案，后续分析不要把它作为节点字段依据。

太刀的入口、成功分支、手动判定窗口、多人过滤、竖直攻击和启动/冲突排查记录，见 [`MOD_DEVELOPMENT_NOTES.md` 的太刀开发记录](MOD_DEVELOPMENT_NOTES.md#10-太刀开发记录已验证)。

## 已确认动作

| Motion | 含义 | 备注 |
| ---: | --- | --- |
| 147 | 见切斩 | 见切成功判定与该动作关联 |
| 151 | 特殊纳刀/居合链 | 自动居合通常从第 76 帧后允许触发 |
| 152 | 特殊纳刀/居合链 | 原版允许阶段 |
| 155 | 手动居合成功判定相关动作 | 手动延后窗口使用 |
| 156 | 特殊纳刀/居合链 | 自动居合通常从第 38 帧后允许触发 |
| 307 | 可派生见切的攻击动作 | 伤害到达时可能已切换到 Motion 1，需缓存上一动作 |

## 已确认节点

| Node ID | 含义 |
| ---: | --- |
| 3716128725 | 自动居合入口 |
| 2004603551 | 居合成功节点；手动延长不可再次跳转到该节点 |
| 532382550 | 见切入口父节点 |
| 1265650183 | 见切活动/判定节点 |
| 3993670187 | 见切成功链节点 |
| 941394064 | 见切成功后续链节点 |
| 4047837507 | 见切动作后续链节点 |

## 见切关键 Action

见切入口父节点 `532382550` 包含以下关键 Action：

| Action | 类型 | 原版字段 | 用途 |
| ---: | --- | --- | --- |
| 9124 | `PlayerFsm2ActionSeeThroughAttack` | `_StartFrame`, `_EndFrame` | 看破成功判定窗口 |
| 9125 | `PlayerFsm2MutekiTimer` | `_AddFrame = 0`, `_AddTime = 40` | 无敌计时，不等于看破成功窗口 |

实测原版见切成功边界约为第 30 帧。手动见切延长应修改 Action `9124` 的 `_EndFrame`；修改 Action `9125` 的 `_AddTime` 只会改变无敌计时，不会延长看破成功判定。

## 已确认 Condition

- 见切活动节点 `1265650183` 使用 Condition `6944`：`PlayerFsm2ConditionQuestBaseSeeThrough`。
- 见切入口节点含 Command Condition `6829-6835`。
- 见切后续节点含 Command Condition `6857-6876`。
- 入口 Command 的常见原版窗口为 `StartFrame = 38`、`EndFrame = 52`、`PreFrame = 20`。

## 文件校验

```text
A47DDA25415B4BBA349B36D39CB807428EDD6E32DFA33DB81A15D96CC7ABE048  LongSword.motfsm2.43
C2AC01F37B258D84FC3AFA99E5B68A190E93E67A58A7F4781BE194088D5C5B0F  LongSword.rcol.20
334CA332FE2CF367F1E8BCF01F27F2823EB3900C0C85425B9E42DFD2D215A975  LongSwordAssist_capture.json
94ACEA8D2F49D5D43320626BE6ECADA87FA97494191DB599F9C1D76BD47EA251  LongSwordAssist_transition_probe_legacy_invalid.json
```
