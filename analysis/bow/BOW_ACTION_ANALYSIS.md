# 弓箭动作分析记录

本文件记录《怪物猎人：崛起》`16.0.2.0`、REFramework TDB `71` 下的弓箭闪身箭斩分析结果。它是维护资料，不是安装说明；动作原始文件和运行时证据分别位于 `../raw` 与 `../captures`。

## 运行时基线

| 项目 | 已确认值 | 说明 |
| --- | ---: | --- |
| 运行时武器类型 | `13` | `master_player._playerWeaponType`；菜单枚举的 `BOW = 10` 不能直接代替 |
| 动作库 | `100` | `Bank 100` |
| 手动闪身箭斩 Motion | `202/203/204/205` | 四个方向的手动动作库 |
| 自动动作确认 Motion | `452/456` | 只用于确认原版动作已经进入，不是手动四向窗口 |
| 四向 NodeIndex | `4281-4284` | 节点数组位置，不是全局 ActionID |

Motion 与 NodeIndex 是两套不同的标识。当前资料确认了四向节点集合，但不把数组顺序当作永久方向映射；更新动作资源后要重新采集方向和 Action。

## 四向 Action

参考 Mod 中的 `Action_gx = 61` 只代表该版本的动作表偏移。由原始索引加偏移得到当前运行时 Action：

| 方向 | 参考原始索引 | 当前 ActionID | 对应 Motion |
| --- | ---: | ---: | ---: |
| 前 | `9173` | `9234` | `202` |
| 后 | `9226` | `9287` | `203` |
| 左 | `9190` | `9251` | `204` |
| 右 | `9208` | `9269` | `205` |

这些 Action 的用途是延长同一次手动闪身箭斩的成功判定。当前 Lua 实现保存每个 Action 的原始 `_EndFrame`，按设置增加延后帧，并在关闭功能、切换 Motion FSM Tree 或重载脚本时恢复原值。它不会再次调用闪身箭斩入口。

## Motion FSM 的 Act10 读取

`4281-4284` 必须先作为 NodeIndex 读取，再从节点数据取得 Act10：

```lua
local nodes = tree:get_nodes()
local node = nodes[4281]                 -- NodeIndex
local raw_index = node:get_data():get_actions()[10]
local action = tree:get_action(raw_index) -- Action object
```

有些工具把 Act10 显示为一基槽位，而 Lua 数组按零基访问；适配时应同时记录槽位 `10` 和 `9` 的原始值、类型、`_StartFrame` 与 `_EndFrame`。节点 Action 值可能带 Static Action 标记，不能先对 `1073741824` 取模再查表；优先把原始值交给 `tree:get_action(raw_index)`。

## 为什么早期会出现 `0 / 0`

`反射动作 / 成功条件` 统计来自诊断 Hook，并不等于四向 Action 的延长写入数。弓在当前版本通常通过 `checkCalcDamage_DamageSide` 进入实际伤害流程，`checkDamageReflexNoDamageHitEnable(...)` 的 Call Count 可以为 `0`。因此：

- `GP 判定次数 = 0` 只说明该候选入口没有被调用；
- `伤害事件数`、`最近攻击来源` 和 `最近伤害流程` 才是实际受击观察点；
- `Motion FSM Act10 目标 / 已修改` 反映四向节点扫描是否找到可写 Action；
- `已知 Action 目标 / 已修改` 反映 `9234/9287/9251/9269` 的直接回退路径。

诊断版同时显示四向目标摘要，不再把最后扫描到的“右”误报成唯一目标。当前测试中四向 Act10 延长达到 `4/4`；关闭延长后，同一提前量恢复原版受击结果。

## 自动 GP 路径

自动 GP 与手动判定延长是两条独立路径：

1. `checkCalcDamage_DamageSide` Hook 确认主玩家、弓 `13`、原版伤害流程和攻击来源。
2. 联机兼容开启时保留 `OwnerType == 1`，并接受 `EmHitAttack`/`DummyHitAttack`；有攻击对象时优先匹配 `em###` 名称。
3. 满足条件后通过 `BehaviorTree:setCurrentNode(...)` 进入原版闪身箭斩节点；短暂 pending 状态只确认 Motion `452/456` 是否进入。
4. 自动 GP 只提交入口，不修改手动成功窗口，也不重复释放动作。

多人同步时攻击对象为空是正常情况，不能仅按空对象拒绝；需要结合攻击类型、OwnerType、任务状态和玩家索引过滤队友攻击。

## 最终自动 GP 修复：同一攻击链的重复 DamageSide 回调

最后一次回归中，单次怪物命中会在相邻帧调用两次
`checkCalcDamage_DamageSide`。第一次回调已经提交原版闪身箭斩入口，但在
`Motion 452/456` 出现前，第二次回调仍可能带着相同攻击继续进入原版受击动作。
这会表现为“界面显示自动 GP 成功，但角色仍被击中”，也容易被误判成周期锁或
弓的持弓状态判断错误。

最终状态机分成四个独立阶段：

1. **入口提交**：第一次符合条件的怪物伤害只提交一次原版闪身箭斩节点。
2. **同链保护**：入口提交后的 `3` 个 Lua 帧内，同一攻击链的重复伤害回调直接
   走拦截返回，不再次提交动作，也不进入受击动作。
3. **动作确认**：只有实际观察到 `Motion 452/456` 才记录自动 GP 动作进入，并
   启动动作周期锁。
4. **动作结束与重置**：周期锁在动作结束后解除；同链保护只覆盖入口等待期，
   不会把连续独立攻击永久锁死。

因此，周期锁不是本次问题的根因；它只负责已经进入闪身箭斩后的重复发动。真正
缺失的是入口到 `452/456` 之间的同一攻击链保护。后续修改入口时必须同时验证：
“第一次请求一次、相邻重复回调拦截、动作中不二次 GP、动作结束后可重新触发”。

## 证据文件

- [`../captures/BowAssist_capture.json`](../captures/BowAssist_capture.json)：完整诊断采集，含武器 `13`、Bank `100`、四向 Motion 变化、`em131_00` 受击、GP 过早/过晚标记和最终同一攻击链重复回调证据。
- [`../raw/natives/STM/player/mot/plf_Bow_100.motlist.528`](../raw/natives/STM/player/mot/plf_Bow_100.motlist.528)：弓 Bank 100 原始 Motion 列表。
- [`../raw/natives/STM/player/mot/plf_Bow_bank.motbank.3`](../raw/natives/STM/player/mot/plf_Bow_bank.motbank.3)：弓动作 Bank 索引。
- [`../raw/natives/STM/player/Fsm/Bow/Bow.motfsm2.43`](../raw/natives/STM/player/Fsm/Bow/Bow.motfsm2.43)：弓 Motion FSM 原始资源。

原始资源来自本机已安装游戏版本，仅用于版本适配和索引核对；不要把它们当作安装文件复制到游戏目录。
