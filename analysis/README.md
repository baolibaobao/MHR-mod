# 动作拆解资料

本目录保存《怪物猎人：崛起》16.0.2.0 的太刀和弓箭动作分析资产，供后续版本适配和功能维护使用。这些文件不是安装包，不应复制到游戏目录。

## 弓箭动作资料

弓箭的独立分析记录见 [`bow/BOW_ACTION_ANALYSIS.md`](bow/BOW_ACTION_ANALYSIS.md)，当前基线为运行时武器类型 `13`、Bank `100`、手动闪身箭斩 Motion `202/203/204/205`。

### 原始动作资源

```text
raw/natives/STM/player/mot/plf_Bow_100.motlist.528
raw/natives/STM/player/mot/plf_Bow_bank.motbank.3
raw/natives/STM/player/Fsm/Bow/Bow.motfsm2.43
```

- `plf_Bow_100.motlist.528`：弓 Bank 100 的原始 Motion 列表。
- `plf_Bow_bank.motbank.3`：弓动作 Bank 索引。
- `Bow.motfsm2.43`：弓 Motion FSM、四向闪身箭斩节点和 Action/Condition 关系。

### 弓运行时采集

```text
captures/BowAssist_capture.json
```

该采集包含弓 `13`、Bank `100`、四向 Motion、`em131_00` 受击、GP 过早/过晚标记和最终同一攻击链重复回调证据。它是诊断证据，不是需要放入游戏目录的配置文件。

四向 NodeIndex `4281-4284`、Act10 读取方式、Action `9234/9287/9251/9269` 和 `Action_gx = 61` 的版本偏移说明，见 [`bow/BOW_ACTION_ANALYSIS.md`](bow/BOW_ACTION_ANALYSIS.md)。

## 目录内容

### 开发工具源码

为方便版本更新，保留本次使用的最小提取工具源码，不包含编译产物：

```text
tools/LongSwordKamuiCapture.lua
tools/bow-fsm-extract/
tools/pak-extract/
```

`bow-fsm-extract` 用于从当前生效 PAK 提取弓 Motion FSM，`pak-extract` 是通用的
PAK/Zstandard 定向提取工具。`bin/`、`obj/`、游戏 DLL、配置和临时备份不纳入仓库。

### 原始拆包资源

```text
raw/natives/STM/player/Fsm/LongSword/LongSword.motfsm2.43
raw/natives/STM/player/hit/LongSword.rcol.20
raw/natives/STM/player/mot/plw_LongSword_100.motlist.528
raw/natives/STM/player/mot/plw_LongSword_bank.motbank.3
```

- `LongSword.motfsm2.43`：太刀 Motion FSM、节点、Action、Condition 和 Transition 的原始资源。
- `LongSword.rcol.20`：太刀碰撞与攻击判定相关资源。
- `plw_LongSword_100.motlist.528`：太刀 Bank 100 的 Motion 列表。
- `plw_LongSword_bank.motbank.3`：太刀动作 Bank 索引。

保留原始游戏路径是为了后续使用 RE_RSZ、010 Editor 或 BHVT 工具时直接定位，不必重新从游戏包中解包。

### 运行时拆解

```text
captures/LongSwordAssist_capture.json
captures/LongSwordAssist_transition_probe_legacy_invalid.json
captures/LongSwordKamui_capture.json
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
47F164E9D22A64D1D88544D7E1BF022E69433CEB9D80ED7865E2F19A2DCBA550  BowAssist_capture.json
2F3F9C1F45D8C0DBD36E73D2E7571E035752C1CA710C79AF84F69056673FE2B3  LongSwordKamui_capture.json
DA18FCDE70656CE1E62E287A834CC4C3EBEACBE62BE0B54C9A73AF2A4F523F85  Bow.motfsm2.43
77D3EC016E2E2017EA8E81EDEE13C4C3C384F5DC37F5C79399382D2E1BF7F8DF  plf_Bow_100.motlist.528
17B2B46449FD4CD5A642469EEC18A89D0723A4D0B1A62898D75D19A814BFBDC1  plf_Bow_bank.motbank.3
2F117D2539EDD873C4FDFC75CD3A01AB49887AC08934E900F7964F64A255A38D  plw_LongSword_100.motlist.528
7446B732D55030CDCCF10424E31040A84CD1B3BC04802C751D22266EDC7C51C9  plw_LongSword_bank.motbank.3
```
