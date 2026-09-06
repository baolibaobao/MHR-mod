# MHR Mod 开发说明

这份文档记录本项目在《怪物猎人：崛起》REFramework Lua Mod 开发中验证过的路径、常见误区和维护方法。重点覆盖太刀辅助与弓闪身箭斩判定。

## 1. 运行时对象路径

玩家的 Motion FSM Tree 可以按下面的路径获取：

```lua
local manager = sdk.get_managed_singleton("snow.player.PlayerManager")
local player = manager:call("findMasterPlayer")
local game_object = player:call("get_GameObject")
local motion_fsm = game_object:call(
    "getComponent(System.Type)",
    sdk.typeof("via.motion.MotionFsm2")
)
local layer = motion_fsm:call("getLayer", 0)
local tree = layer:get_tree_object()
```

动作、节点和当前运行状态是三套不同数据：

```lua
local actions = tree:get_actions()
local nodes = tree:get_nodes()
local action = tree:get_action(ActionID)
local node = tree:get_node_by_id(NodeID)
```

## 2. NodeIndex、NodeID、ActionID

这三个数字必须区分使用：

| 名称 | 获取方式 | 含义 |
| --- | --- | --- |
| `NodeIndex` | `tree:get_nodes()[index]` | 节点在节点数组中的位置 |
| `NodeID` | `node:get_id()` | 节点自己的运行时 ID |
| `ActionID` | `tree:get_actions()[index]` 或 `tree:get_action(index)` | 全局 Action 表中的位置 |
| `Act10` | `node:get_data():get_actions()[10]` | 某个 Node 的第 10 号 Action 槽位 |

弓四向闪身箭斩的资料中，`4281–4284` 是四个 NodeIndex。它们不是四个全局 ActionID；正确读取方式是：

```lua
local node = tree:get_nodes()[4281]
local act10_index = node:get_data():get_actions()[10]
local act10 = tree:get_action(act10_index)
```

不同工具对 Act 槽位可能使用零基或一基标签。遇到 `Act10` 对不上时，可以同时检查数组下标 `10` 和 `9`，并把实际数组值、类型和字段记录下来，避免只凭标签猜测。

## 3. 直接读取 Action 表

当前弓 Lua 参考 Mod 的核心是：

```lua
local actions = tree:get_actions()
local action = actions[ActionID]
action:set_field("_EndFrame", target_end)
```

更稳妥的封装如下：

```lua
local function get_action_object(tree, index)
    if tree == nil or index == nil then return nil end
    local ok, action = pcall(function() return tree:get_action(tonumber(index)) end)
    if ok and action ~= nil then return action end
    local ok_list, actions = pcall(function() return tree:get_actions() end)
    if ok_list and actions ~= nil then
        local ok_item, item = pcall(function() return actions[tonumber(index)] end)
        if ok_item then return item end
    end
    return nil
end
```

优先调用 `tree:get_action(raw_index)`，因为节点 Action 数组中的值可能包含 Static Action 标记。

### Static Action 陷阱

BHVT/节点 Action 数组中的第 30 位可能表示 Static Action：

```text
STATIC_ACTION_BIT = 1 << 30 = 1073741824
```

不要无条件执行下面的操作：

```lua
raw_index = raw_index % 1073741824
```

这样会丢掉 Static 标记，导致取到错误的普通 Action 或得到 `nil`。应保留原始索引，交给 `tree:get_action(raw_index)` 解析；只有在确认是普通 Action 后，才使用普通 Action 表下标。

## 4. 弓闪身箭斩判定

本地可用参考 Mod：

```text
F:\ruanjian\guailiemod\弓\reframework\autorun\g.lua
```

其中 `Action_gx = 61`，四个延迟判定 Action 为：

| 方向 | 参考原始索引 | `+ 61` 后的 ActionID |
| --- | ---: | ---: |
| 前 | 9173 | 9234 |
| 后 | 9226 | 9287 |
| 左 | 9190 | 9251 |
| 右 | 9208 | 9269 |

参考实现只修改这四个 Action 的 `_EndFrame`。它没有依赖每次动作变化，也没有重新释放闪身箭斩，因此适合实现“同一次手动闪身箭斩的成功窗口延长”。

`Action_gx` 是版本偏移，不是永久常量。游戏、拆包资源或其它 Mod 改变 Action 表后，必须重新验证 Action 类型和 `_StartFrame/_EndFrame`。

## 5. 延长窗口的正确语义

DamageReflex 常见字段：

| 字段 | 作用 |
| --- | --- |
| `_StartFrame` | 判定开始帧 |
| `_EndFrame` | 判定结束帧 |
| `_AddTime` | 无敌计时或附加计时，不等于成功判定窗口 |

只想延长成功判定时，优先修改 `_EndFrame`。修改 `PlayerFsm2MutekiTimer._AddTime` 只会改变无敌计时，不会让看破或 GP 更容易成功。

修改流程应保存原值，并只在目标值变化时写入：

```lua
if originals[action] == nil then
    originals[action] = action:get_field("_EndFrame")
end
local target = originals[action] + config.post_frames
if action:get_field("_EndFrame") < target then
    action:set_field("_EndFrame", target)
end
```

关闭功能、切换 Tree 或卸载脚本时恢复原值，避免把测试值永久留在运行时对象中。

## 6. Hook 路线与直接 Action 路线

### 直接 Action 路线

适合在 Tree 和 Action 表已经就绪时使用：

```text
获取 Motion FSM Tree
读取 tree:get_actions()[ActionID]
确认 Action 类型和帧字段
缓存原值
修改 _EndFrame
```

优点是开销小、不会重复释放动作，适合四个固定方向的窗口扩展。缺点是 ActionID 会随版本和动作表偏移变化。

### Hook 路线

可观察的候选入口包括：

```text
snow.player.PlayerQuestBase.checkCalcDamage_DamageSide
snow.player.PlayerQuestBase.checkDamageReflexNoDamageHitEnable(...)
```

`checkCalcDamage_DamageSide` 更适合识别实际受击、攻击来源和伤害流程；`checkDamageReflexNoDamageHitEnable` 是否被某个武器调用，需要用 Hook 工具确认 Call Count。不同武器可能走不同的反射路径，太刀调用过某个入口并不代表弓也会调用。

生成的 Static Action 有时不会通过简单的全表扫描暴露出来。此时 Hook 可以记录运行时传入的反射对象和字段，再决定是否修改。Hook 回调中要保存玩家索引、动作号和攻击来源，避免把队友攻击或其它玩家的受击事件算进主玩家。

## 7. 诊断与性能

建议在 ImGui 中显示以下最小状态：

```text
武器类型
动作库 / 动作
当前 NodeID
最近攻击来源
最近伤害流程
目标 Action 数 / 成功写入数
最后一次 Action 类型和帧范围
```

不要每帧扫描 4993 个节点。优先顺序：

1. 直接读取已确认的 ActionID。
2. 只扫描已确认的 NodeIndex，例如弓 `4281–4284`。
3. 只有在版本适配阶段，才按帧分批扫描全树。

所有运行时调用都应做空值和异常保护：

```lua
local ok, value = pcall(function() return object:get_field("_EndFrame") end)
```

长字符串诊断只写入 JSON，界面只显示截断后的摘要，避免覆盖游戏画面。

## 8. 攻击来源与联机兼容

自动 GP/自动居合的伤害过滤建议同时检查：

```text
OwnerType == 1
攻击类型包含 EmHitAttack 或 DummyHitAttack
攻击对象名称符合怪物对象格式
```

多人任务中攻击对象可能为空，空对象需要结合 OwnerType、攻击类型和任务状态判断，优先保留为待确认事件。自动功能默认关闭，联机兼容模式和多人任务检测默认开启，降低测试时误触发的概率。

## 9. 已踩过的坑

### 只判断 452/456

弓四向手动闪身箭斩实际进入 `202/203/204/205`。只判断 `452/456` 会让延长逻辑完全错过真正的手动动作。

### 把 4281 当成 ActionID

`4281–4284` 是 NodeIndex。直接读取 `tree:get_actions()[4281]` 得到的是其它普通动作，例如 `ResetAimRotate`，与 GP 判定无关。

### 丢掉 Static 标记

对节点数组中的原始 Action 索引取模会破坏 Static Action 标志，造成类型错误或 `nil`。

### 只按类型名匹配

部分版本或生成对象的类型名不是完整的 `PlayerFsm2ActionDamageReflex`。在已锁定的四向节点中，应同时检查 `_StartFrame` 和 `_EndFrame`，并把类型名记录下来。

### 把 `_AddTime` 当成成功窗口

`MutekiTimer` 的计时和 GP/见切成功条件是两件事。延长无敌时间不等于延长成功判定。

### 用跳节点代替动作判定

自动 GP 可以通过 `BehaviorTree:setCurrentNode(...)` 进入原版闪身箭斩，但这只覆盖自动触发入口；手动成功窗口仍需要修改真正的 DamageReflex Action 或运行时反射对象。

### 不缓存动作切换前状态

伤害 Hook 执行时，MotionID 可能已经从 GP 动作切换到受击或后续动作。需要缓存上一动作、Bank 和帧数，单独读取 Hook 回调瞬间的状态不够可靠。

## 10. 太刀开发记录（已验证）

本节只记录太刀 `LongSwordAssist.lua` 的实际运行结果和维护规则。太刀与弓保持为两个独立 Lua Mod；弓的四向 Node/Action 需要重新确认后才能用于太刀。

### 10.1 运行时基线和关键 ID

当前测试基线是游戏 `16.0.2.0`、REFramework TDB `71`。太刀运行时读数固定为武器类型 `2`、动作库 `Bank 100`。下面的数字属于当前版本的运行时 ID，更新游戏或更换动作资源后必须重新验证：

| 项目 | ID/数值 | 用途 |
| --- | ---: | --- |
| 允许见切状态 | `295` | Transition/Node 数据中的原版可见切状态 |
| 自动居合入口 | `3716128725` | 受击后进入原版特殊纳刀/居合入口 |
| 居合成功节点 | `2004603551` | 原版成功分支；手动延长时保持原动作链 |
| 见切入口父节点 | `532382550` | 自动见切起手入口 |
| 见切活动节点 | `1265650183` | 见切动作和判定阶段 |
| 见切成功节点 | `3993670187` | 看破成功分支 |
| 见切后续节点 | `941394064`、`4047837507` | 成功后的原版后续链 |
| 见切成功 Action | `9124` | `PlayerFsm2ActionSeeThroughAttack`，真正的成功判定窗口 |
| 见切无敌 Timer | `9125` | `PlayerFsm2MutekiTimer`，只负责无敌计时 |

常见 Motion 也要和 NodeID 分开记录：

| Motion | 含义 | 维护重点 |
| ---: | --- | --- |
| `147` | 见切斩动作 | 进入后等待原版成功分支，不要每帧重复跳转 |
| `151`、`152`、`156` | 特殊纳刀/居合链 | 自动居合入口和手动居合反射窗口 |
| `155` | 手动居合成功判定相关动作 | 受击时检查延后窗口 |
| `307` | 可派生见切的攻击动作 | 伤害回调时经常已经切换，必须缓存上一动作 |

`295` 是状态标记，不是动作号；`147` 是 Motion，不是成功 Node；`9124` 是 Action，不是 Node。把这些数字放入同一张“动作表”或把 NodeIndex 当成 ActionID，会得到看似就绪但实际不工作的诊断结果。

### 10.2 自动居合：入口、角度和原版动作

自动居合当前走 `snow.player.PlayerQuestBase.checkCalcDamage_DamageSide` 伤害 Hook：

1. 先确认受击接收者是主玩家（`_PlayerIndex == master_index`），再确认武器类型 `2`、Bank `100`。
2. 只允许原版特殊纳刀阶段：Motion `151` 通常从约第 `76` 帧开始，Motion `152` 为原版允许阶段，Motion `156` 通常从约第 `38` 帧开始。
3. 从玩家位置、朝向和攻击对象位置计算带符号水平角。配置的 `120` 度是总覆盖角，也就是左右各 `60` 度；`abs(angle) <= 60` 才允许自动触发。
4. 通过 `BehaviorTree:setCurrentNode(NODE_AUTO_IAI_ENTRY)` 进入原版居合入口。成功分支沿原版 Transition 继续，受击回调只提交一次入口请求。
5. 使用短冷却避免同一段伤害流程重复触发。成功与否交给游戏原版动作和伤害流程判定，脚本只负责选择入口。

背向攻击不触发是设计条件，不是故障；这样可以避免角色背对攻击时自动纳刀后位移错位。手动居合延长也不应被自动入口逻辑再次跳转。

### 10.3 自动见切：允许动作和成功分支

自动见切和自动居合是两条独立的入口。当前动作允许表包含原版可派生范围 `4-8`、`10`、`13-15`、`101-109`、`307`；同时沿当前 Node 及父节点检查是否包含状态 `295`，用于动作表变化时的动态兜底。站立或没有原版见切 Transition 的动作保持原版行为。

自动见切流程分为两段：

1. 伤害到来且动作在正面角度内时，跳到 `532382550`（节点未就绪时使用 `1265650183` 作为运行时兜底），这一步只是释放原版看破斩。
2. 进入 Motion `147` 后，等待 `auto_foresight_success_delay`，再一次性跳到 `3993670187` 成功节点。成功分支只执行一次，并由 pending 标记和冷却清除。

“见切斩释放”和“看破成功”不是同一个事件：前者表示动作起手，后者必须走原版成功链并由伤害流程返回成功。以前把成功节点和入口同时调用，会出现看破斩连续释放两次；以前立即跳成功节点，会出现动作已经释放但看破没有成功。调试自动见切时应分别记录 `最近请求`、`伤害瞬间动作`、`最近伤害流程` 和 `请求节点`。

### 10.4 动作 307 与上一动作缓存

动作 `307` 是可派生见切的攻击动作，但伤害 Hook 的执行顺序可能是：

```text
307（玩家仍可见切） -> Motion 1/受击过渡 -> checkCalcDamage_DamageSide 回调
```

因此只读取 Hook 瞬间的 `motion_id` 会把合法动作误判为“不允许见切”。当前做法是在 `PlayerMotionControl.lateUpdate` 中缓存主玩家的 `_OldBankID/_OldMotionID`，命中 `Bank 100 + 允许 Motion` 后保留短暂 `foresight_legal_grace`；伤害回调同时检查当前 Motion、缓存 Motion 和缓存帧。这个缓存只用于识别入口，不代表要再次释放看破斩。

### 10.5 手动居合延长：只延长同一次判定

手动居合的目标是“同一次特殊纳刀成功窗口变长”，而不是受击后再释放一次居合。实现规则如下：

- 从 `PlayerQuestBase.get_DamageReflex()`（以及兼容 getter/字段）取得当前反射对象。
- 只在 Motion `151/152/155/156` 活动时缓存该对象和原始 `_EndFrame`，随后把 `_EndFrame` 增加 `iai_post_frames`。
- 手动居合的起始输入由对应 Transition Condition 的 `PreFrame` 增加 `iai_pre_frames`；这只改变输入可接受范围，不跳转成功节点。
- 受击回调中，Motion `155` 的原版结束边界约为第 `8` 帧，只有落在 `8 < frame <= 8 + iai_post_frames` 才记录“手动居合延长判定”。
- Motion、Tree 或反射对象变化时恢复原值；关闭选项和卸载脚本也必须恢复，避免测试值残留。

曾经出现“手动居合多释放一次”的原因，是把自动成功节点复用到手动判定路径。修复后手动路径只改当前 DamageReflex 的帧范围，成功由原版 `DamageSide` 返回值决定，动作始终只释放一次。

### 10.6 手动见切延长：9124 与 9125 的区别

手动见切延长必须改成功判定 Action `9124`：

```text
类型：PlayerFsm2ActionSeeThroughAttack
字段：_StartFrame / _EndFrame
原版成功结束边界：约第 30 帧
目标结束边界：原版结束帧 + foresight_post_frames
```

`9125` 的类型是 `PlayerFsm2MutekiTimer`，`_AddTime = 40` 只会改变无敌计时，不会扩大看破成功判定。把 `9125` 调大后“无敌时间变长但看破仍失败”是预期现象，成功窗口仍需修改 `9124`。

见切起手的提前输入还涉及入口 Transition Condition（常见原版 `StartFrame = 38`、`EndFrame = 52`、`PreFrame = 20`，命令类型可能为 `155/196/37/38`）。提前输入与成功延后是两个设置：前者改 Condition 的 `PreFrame`，后者改 `9124._EndFrame`。两者都要缓存原值、按 Tree 重新发现并在关闭时恢复。

帧数是 Motion 帧而非毫秒。命中落在原版约第 30 帧以前时，调大 `foresight_post_frames` 不会改变结果；只有命中位于原版结束边界与新结束边界之间时才会记录延长成功。因此测试中 `12/16` 看不出变化、调到约 `30/35` 才容易命中，并不表示入口再次释放；应先在界面确认 `9124` 的原始/目标 `_EndFrame`。

当 `最近触发` 没有显示手动见切延长时，先检查 `9124` 的类型、当前对象是否为本次见切实例、伤害流程是否返回原版成功分支，再检查 UI 文本映射；不要通过再次调用见切入口来“补判定”。

### 10.7 伤害来源、竖直攻击和联机模式

伤害过滤是自动功能的入口条件，手动延长成功沿原版动作链完成。当前建议顺序：

```text
接收者主玩家 -> OwnerType == 1 -> EmHitAttack/DummyHitAttack
-> 有对象时名称匹配 em### -> 无对象时结合任务/网络状态判断
```

多人任务中 `AttackObject` 为空是正常同步形态。来源对象为空时保留 `OwnerType`、攻击类型和任务状态，诊断界面可显示“多人同步怪物攻击”；队友攻击过滤只作用于自动居合/自动见切入口，手动居合和手动见切沿原版判定。

联机设置的作用是改变来源过滤和同步兼容，不是把所有功能硬编码为多人关闭。当前默认值为：自动居合关闭、自动见切关闭、联机兼容开启、自动检测多人任务开启；进入多人任务后由玩家自行打开自动功能。曾经出现“单人有效、多人无效、攻击来源为空”的根因，是把网络事件的空对象当成无效来源，或只检查了不被该武器调用的反射入口。

`checkDamageReflexNoDamageHitEnable(...)` 的 Call Count 为 `0` 时，先视为“该入口未被当前版本太刀路径调用”，继续以 `checkCalcDamage_DamageSide` 作为实际受击观察点；迁移版本时再用 Hook 记录两个入口的调用次数和参数类型。

`checkCalcDamage_DamageSide` 的返回值也要单独记录：

| 返回值 | 当前用途 |
| ---: | --- |
| `0` | 原版伤害流程继续；满足来源、角度和动作条件时才提交自动入口 |
| `2` | 原版无伤/反射成功分支；用于记录手动居合或手动见切延长成功，保留原返回值 |
| 其它 | 交给原版处理，脚本透传原值 |

自动功能只在原版流程仍处于可接管阶段时提交请求；手动延长只观察成功返回值。把“返回值 2”误当成需要再次释放动作，会再次产生重复居合或重复见切。

头部下砸、脚底上挑等攻击的来源向量可能几乎没有水平投影。处理顺序应为：

1. 先用攻击对象位置计算水平角。
2. 水平投影接近零时改用 `DamagedDirection`。
3. 两者都显示为纯竖直且垂直分量明显时，将水平角按 `0`（中性正面）处理；没有垂直证据时仍返回无效并拒绝自动触发。

这项兼容只解决“没有可用水平角”的竖直来源；真实背向攻击仍按 `120` 度范围过滤。

### 10.8 诊断、采集和性能陷阱

- `核心节点就绪`、`自动居合节点就绪`、`当前动作允许见切`、`见切成功判定动作就绪` 是四个不同状态。Tree 尚未初始化、节点 ID 版本不匹配或行为树组件为空时，它们可以暂时为“否”；需结合 `武器类型`、`Bank/Motion`、`当前节点`、`伤害瞬间动作`、`最近伤害流程`、`请求节点` 和 `节点调用成功` 一起判断 Hook。
- `Mark Iai test`、Transition 探针等采集按钮只记录诊断，不代表一定能触发动作。测试未按成功时应保留“未命中/过早/过晚”事件，而不是把 0 次成功写成节点不存在。
- 静态 Transition 探针中出现的 `nil` 节点对象只代表该探针路径无效。任务内应通过 `get_motion_tree()` 获取实际 Tree，再用 `tree:get_nodes()`、`tree:get_node_by_id()` 和 `tree:get_actions()` 读取。
- 诊断版曾因每帧扫描全节点、输出过多日志导致卡顿和闪退；轻量版稳定。运行时只直接读取已确认 Action，节点扫描按小批次执行，完整 Transition 采集只执行一次，长字段写 JSON 而不是每帧刷 ImGui。
- 中文状态文本必须经过统一映射，例如 `manual iai extended window` 映射为“手动居合延长判定”、`manual foresight extended window` 映射为“手动见切延长判定”，避免功能已生效但界面仍显示英文。
- 当前界面仍是 REFramework 的 Script Generated UI；独立 ImGui 窗口属于后续工作，界面路径需单独记录。

### 10.9 启动闪退和 Mod 冲突排查

已观察到的“刚打开游戏、窗口没有焦点就闪退，聚焦后正常”更像 Launcher/OnlineFix、D3D12 覆盖层或 REFramework 初始化时序问题，不等价于太刀动作逻辑错误。排查顺序：

1. 启动到标题画面前保持游戏窗口聚焦。
2. 用最小 Mod 集合启动，只保留 REFramework 和目标 Lua。
3. 临时停用整套 `motbank/motlist`、女性角色 prefab/贴图及其它会改 Motion/Prefab 的 Mod，确认是否改变动作表或覆盖层初始化。
4. 若更新后打不开，先恢复最近一次游戏根目录备份，再逐项恢复 Mod；记录启动日志和崩溃时间。

覆盖游戏根目录文件前必须先备份原文件到工作区的 `备份/<时间戳>`，保存 SHA-256；配置文件和用户设置单独备份。转储/日志放在工作区诊断目录，避免继续占用系统盘；清理旧转储前先确认对应日志已经归档。

旧版单人自动见切曾经正常，主要因为固定入口和较宽松的动作判断在单人事件中恰好能命中；后续加入“只允许原版动作”和多人来源过滤后，`307 -> 受击` 的时序、网络空对象以及过早成功跳转会暴露出来。后续版本适配应把动作合法性、来源合法性、入口请求和成功分支分开验证，回归测试需同时覆盖单人和多人。

### 10.10 太刀回归测试顺序

每次改动后按固定顺序测试，避免把入口问题和判定问题混在一起：

1. 无其它动作替换 Mod，确认武器 `2`、Bank `100`、Motion/Node 会随动作变化。
2. 单人正面攻击：自动居合、自动见切分别测试；再测背向，确认不触发。
3. Motion `307` 派生见切：记录伤害瞬间动作和上一动作缓存，确认只释放一次并能走成功分支。
4. 手动居合和手动见切分别测试过早、原版窗口、延后窗口；确认“最近触发”只在 DamageSide 成功时变化。
5. 头部下砸、脚底上挑等纯竖直来源测试，确认中性角兼容而非全向放开。
6. 多人任务测试怪物攻击、队友攻击和 `AttackObject` 为空的同步事件；确认联机兼容只过滤来源，不屏蔽手动判定。
7. 退出游戏后再分析 JSON/日志，不在游戏运行时反复切换大规模探针；发现异常先回滚备份。

### 10.8 神威居合：固定动作表优先于运行时扫描（2026-09-05）

神威居合初版曾尝试扫描运行时 Motion FSM 的 Action 类型（`IaiCounter`、
`SetIaiData` 等）来判断当前模式。这条路线在实际游戏中显示“未探测到”，
原因是运行时对象可能使用静态 Action 索引、节点对象为空，且神威和普通居合
共享部分行为树入口；类型扫描结果不能作为功能触发条件。扫描还会增加逐帧遍历
节点的开销。

已从当前游戏的覆盖包 `re_chunk_000.pak.patch_001.pak` 重新提取：

```text
资源/natives/STM/player/Fsm/LongSword/LongSword.motfsm2.43
MHR-mod-repository/analysis/raw/natives/STM/player/Fsm/LongSword/LongSword.motfsm2.43
大小：2,167,548 字节
SHA-256：A47DDA25415B4BBA349B36D39CB807428EDD6E32DFA33DB81A15D96CC7ABE048
```

同时保存了动作编号对应的原始动作资源：

```text
analysis/raw/natives/STM/player/mot/plw_LongSword_100.motlist.528
大小：3,796,256 字节
SHA-256：2F117D2539EDD873C4FDFC75CD3A01AB49887AC08934E900F7964F64A255A38D

analysis/raw/natives/STM/player/mot/plw_LongSword_bank.motbank.3
大小：3,076 字节
SHA-256：7446B732D55030CDCCF10424E31040A84CD1B3BC04802C751D22266EDC7C51C9
```

训练场运行时已确认神威动作表：`Motion 161` 是神威居合准备/纳刀，`162` 是
神威居合化解，`163` 是蓄力完成，`164` 是蓄力完成后一段时间，`170` 是气刃
解放斩。截图中 `Bank 100 / Motion 161` 的当前节点为运行时生成的节点 ID，
不作为固定入口。当前实现固定使用 Motion `161` 作为神威居合识别条件，并继续
调用原版居合入口，让游戏保留当前居合模式；不再扫描 IaiCounter 类型，也不把
扫描成功与否当作触发前提。

第一次手动成功采集重新确认了瞬时过渡：`Motion 161`、帧约 `54.00`、节点
`2874088718`，下一采样帧进入 `Motion 162`、帧约 `1.50`、节点
`2605267967`。此前截图中出现的 `3569005589` 是动作继续运行后的其它节点，
不能把它直接当作 `161 -> 162` 的成功入口。自动神威的目标必须以这组前后帧和
对应的 Transition/Condition 为准，不能只凭动作结束时的 NodeID 猜测。

神威受击的 `DamageSide` 返回值可能为 `2`，自动入口同时覆盖 `0` 和 `2` 两条
流程，手动延长仍保持原返回值。当前自动脚本里的成功节点请求属于待回溯项，
在完成 Transition 采集前不把 `3569005589` 固定为正式入口。

维护注意：版本更新后先从实际生效的主包和 patch 包提取 Long Sword FSM，
用动作 ID 显示工具确认神威纳刀 Motion，再更新静态动作表。只有在静态资源无法
确认时才增加一次性诊断，不应恢复逐帧全树扫描作为正式逻辑。

拆包工具注意：本次验证使用工作区 `_scratch/pak_extract/PakExtract.exe` 的纯
命令行流程直接读取 PAK 和 Zstandard 数据，不需要启动 010 Editor。若出现带有
“The Setup program accepts optional command line parameters”的窗口，说明误启动了
010 Editor 安装程序，不是 PAK 或 Lua 错误；关闭该窗口即可，不能把安装程序当作
拆包器调用。

### 010 Editor Setup 弹窗的明确处理规则（2026-09-05）

本次再次出现的窗口来自：

```text
F:\ruanjian\guailiemod\010editor\010editor\010 Editor v10.0 x64.exe
```

这个文件是 010 Editor 的安装程序，不是已经安装好的编辑器命令行工具。对它
传入 `/?`、`/HELP` 或其它拆包参数时，安装程序只会显示 `The Setup program accepts
optional command line parameters` 帮助页，因此截图中的标题是 `Setup`。

处理方式：

1. 关闭 Setup 窗口即可，不要用它打开 PAK，也不需要为了这个弹窗手动安装。
2. PAK 提取统一使用工作区的 `_scratch/pak_extract/PakExtract.exe`，或使用
   `工具/MonsterHunterRiseModding/files/REtool.exe -h mhrisePC.list -x`。
3. 010 Editor 只作为图形化查看/运行 `RE_RSZ.bt` 模板的工具；确认实际安装路径
   后再启动主程序，不能把安装包文件名当成主程序调用。
4. 后续脚本、文档和自动化命令中禁止对上述 Setup 文件执行帮助参数；运行前先检查
   进程窗口标题是否为 `Setup`，若是则立即关闭并回到命令行拆包流程。

该弹窗与 REFramework、`LongSwordAssist.lua`、游戏闪退和神威居合动作逻辑无关，
不会改变游戏文件或采集 JSON。

### 10.8.1 神威居合入口定位：本次误判原因与正确流程（2026-09-05）

#### 本次误判的根因

1. **把动作结束状态当成入口。** 静态资源和 BHVT 会同时展示准备、化解、蓄力和
   后续攻击节点。只看成功动作停留时的截图，会把后续 Node 当成 `161 -> 162`
   的入口；本次前后帧采集证明瞬时目标是 `2605267967`，不是此前选用的
   `3569005589`。
2. **混用了四种 ID。** Motion `161/162` 是动作号，`2874088718`、
   `2605267967`、`3569005589` 是 NodeID，`tree:get_nodes()[index]` 的位置又是
   NodeIndex，Action 还有独立的全局索引。四者放在同一张“动作表”里会得到
   “节点调用成功但动作不变”的假阳性。
3. **只跳 Node，没有执行原版过渡。** `BehaviorTree:setCurrentNode` 可以让诊断
   读数换成目标节点，但神威化解依赖当前动作、伤害反射条件和 Transition Event
   一起执行。直接请求成功 Node 会绕过这些条件，所以角色可能仍停在 Motion 161。
   另外，`master_player:getMotionLayer(0)` 与 `MotionFsm2:getLayer(0)` 不是同一个
   调用层：前者适合读取玩家动作帧，后者才持有 `motfsm2` Tree，并支持 BHVT 编辑器
   使用的 `setCurrentNode(System.UInt64, via.behaviortree.SetNodeInfo,
   via.motion.SetMotionTransitionInfo)`。把完整过渡签名调用在前者上，即使 `pcall`
   返回成功，也可能只更新请求状态而不执行动作。
4. **第一次采集使用了错误的对象调用层。** Motion FSM 的 Node/NodeData 是原生
   wrapper，不能按 managed object 的 `object:call(...)` 方式读取。第一次探针因而
   得到 Node 类型字符串而没有 `Action/Condition/Transition` 数组；这会造成“拆包
   没找到”的假象。原生对象应直接调用 `node:get_data()`、
   `data:get_actions()`、`data:get_transition_events()`。
5. **静态图不能单独告诉我们运行时选中了哪条边。** `motfsm2` 记录的是完整图，
   运行时还会受当前动作帧、DamageReflex 实例、伤害流程返回值和网络事件影响。只
   扫描固定 Node 或只看 `getCurrentNodeID`，都不足以确定真实成功分支。

#### 后续武器动作的正确定位流程

```text
有效 PAK/补丁层
  -> 离线提取 motfsm2/motlist/motbank
  -> 010/RE_RSZ 展开 Node11.childnodes
  -> 记录 NodeIndex、NodeID、父子关系
  -> 读取每个候选 Node 的 Action/State/Condition/Transition Event
  -> 游戏内关闭自动功能，采集成功前后至少 2-3 帧
  -> 用 Motion + NodeID + 当前帧匹配静态节点和 Transition
  -> 确认成功条件后，再复用原版状态链实现自动功能
```

具体要求：

- 静态分析阶段先定位动作资源和候选图，不把 `MotionID` 当 NodeID，也不把
  NodeIndex 当 ActionID；每条边同时保存 `mStates`、`mTransitions`、Condition
  索引、Transition Event 索引和 Action 槽位。
- 运行时采集要记录 `Bank/Motion/Frame`、行为树当前 Node、Motion Layer Tree
  当前 Node、上一帧状态、DamageSide 返回值、DamageReflex 对象和攻击来源。成功
  入口以“上一帧 -> 当前帧”的变化确认，不能以最终停留节点确认。
- 如果 Node 是原生 wrapper，使用直接方法读取；managed 对象才使用
  `object:call`/`get_field`。探针必须把调用失败单独写入 JSON，不能用 `nil` 代替
  “没有 Action”。
- 实现阶段优先让原版 Condition/Transition 自己完成成功分支；脚本只选择合法的
  入口或修改判定窗口。需要跳转时必须使用 `MotionFsm2:getLayer(0)` 返回的 FSM
  Layer 和完整过渡签名，并在下一帧验证 Motion 是否真的变化；“调用返回成功”不
  等于动作执行成功。`getMotionLayer(0)` 只用于读帧，不能替代 FSM Layer。
- 自动神威请求不能仅凭 `pcall` 成功就把 `DamageSide` 返回值强制改成无伤。若 FSM
  没有接受目标 Node，这会出现“仍停在 Motion 161、但攻击不扣血”的假成功。请求后
  应等待下一帧确认 Motion 162；未确认时透传原始伤害流程，并只安排有限次数重试。
- 版本适配时只做一次性的定向采集：先读已知动作附近的节点，再按父子边回溯；正式
  逻辑不恢复逐帧全树扫描。这样可以同时避免漏掉动态节点和造成卡顿/闪退。

#### 本次采集的有效证据

```text
前状态：Bank 100 / Motion 161 / Frame 54.00 / Node 2874088718
后状态：Bank 100 / Motion 162 / Frame 1.50  / Node 2605267967
```

第二次采集还展开了两个关键 Node 的动作内容：

| NodeID | 名称/用途 | 关键 Action | State/Condition |
| ---: | --- | --- | --- |
| `2874088718` | `Motion 161` 神威准备节点 | `9548`：`PlayerFsm2ActionMotionSpdSkillWeaponOffIaiCounter` | 叶节点，无成功动作 |
| `2605267967` | `Motion 162` 手动成功节点 | `9461`：`PlayerFsm2ActionLongSwordSuccessIaiCounter`，同节点还包含 `9460`：`PlayerFsm2ActionSeeThroughAttack` | States `236/4335`；Conditions `1073744384/7082` |

`2605267967` 的完整 Action 序列为 `9457-9466`，其中 `9461` 才是神威成功
Action；`3569005589` 的 `9513` 也属于同类型成功 Action，但它对应的是后续
“カウンター成功”分支。后续实现应以手动成功瞬时边 `2874088718 -> 2605267967`
为入口证据，再回溯其父节点和 Condition，而不是从多个包含同名成功 Action 的
节点中任选一个。

### 10.8.2 自动神威“最近触发但仍受击”修复（2026-09-06）

此前自动神威在 DamageSide 中只要 `setCurrentNode` 的 `pcall` 返回成功，就
立即显示“最近触发”。这只能证明 Lua 调用了接口，不能证明 FSM 接受了
`161 -> 162`；因此会出现界面显示触发、角色仍停在 Motion 161、伤害照常命中的
假成功。

当前本地版本改为：

1. 首次请求同时提交已验证的 `BehaviorTree:setCurrentNode` 和
   `MotionFsm2Layer:setCurrentNode(...SetMotionTransitionInfo)` 两条原版路径。
2. DamageSide 返回时只在请求已提交的情况下沿用自动居合的无伤返回值；不再把
   请求调用本身写成成功事件。
3. 后续 3 帧检查动作是否真正进入 Motion 162；只有确认后才更新“最近触发”。
4. 若仍停在 Motion 161，最多切换路径重试一次，随后显示“未确认”和拒绝原因，
   避免无限重试及误报。
5. 诊断界面记录请求路径、请求前动作/节点和验证状态，便于区分接口返回、动作
   过渡和伤害流程三个阶段。

采集脚本同时改为启动时加载并保留已有 `LongSwordKamui_capture.json`，不再无条件
用空对象覆盖历史采集；静态 Condition 解析优先调用 `tree:get_condition(index)`，
并对带 Static 标记的索引回退到静态条件表。

这组数据只确认了真实动作过渡的两端，尚未替代完整的 Condition/Transition
记录；后续自动神威实现必须以补全后的采集 JSON 为依据。第一次探针 JSON 的
Node 详情为空应归类为“原生对象读取方式错误”，而不是“FSM 中没有该节点”。

### 10.8.3 自动神威成功回归记录（2026-09-06）

用户已确认当前版本自动神威居合成功，角色能从 Motion 161 正常进入神威居合
化解 Motion 162。成功原因不是更换了动作或伪造伤害，而是修正了请求层和验证时序：

- 入口使用手动成功采集确认的 `NodeID 2605267967`，对应 Motion 162 中的
  `PlayerFsm2ActionLongSwordSuccessIaiCounter`，不再使用后续分支
  `3569005589`。
- 受击前同时提交 BehaviorTree 的通用 `setCurrentNode` 和 MotionFsm2Layer 的
  `SetMotionTransitionInfo` 过渡请求，覆盖了两层对象在不同运行时版本中的暴露差异。
- 伤害 Hook 在原版 DamageSide 流程内提交请求，并沿用自动居合的无伤返回，避免
  伤害结算先于动作切换完成。
- 请求后连续检查动作状态，只有实际看到 Motion 162 才更新“最近触发”；接口
  `pcall` 返回成功但动作未切换时会进入一次有限重试，不再产生假成功提示。
- 采集脚本改为保留历史 JSON，后续分析可以继续使用有效的 Motion 161 -> 162
  前后帧证据，不会因启动脚本而被空结果覆盖。

本次回归结论：神威自动化的关键是“正确的成功 Node + 正确的 FSM 请求层 +
动作切换后的确认”，三者缺一都会出现“显示触发但仍受击”或进入普通居合的现象。

## 11. 弓箭开发记录（2026-09-03）

本节记录弓箭 `BowAssist.lua` 当前版本的实现和已完成采集。弓箭与太刀是两个独立 Lua Mod；弓箭动作表、NodeIndex 和成功窗口不能直接套用太刀的数字。

### 11.1 运行时基线

- 游戏版本：`16.0.2.0`，REFramework TDB `71`。
- `_playerWeaponType = 13` 是运行时弓类型；开始菜单枚举中的 `PlayerWeaponType.BOW = 10` 不能用于运行时判断。
- 动作库为 `Bank 100`。手动闪身箭斩的四向动作库是 `Motion 202/203/204/205`，不是早期误判的 `452/456`。
- `Motion 452/456` 仅用于自动入口已经进入原版闪身箭斩后的执行确认。

### 11.2 四向 Node 和 Action

四向 Motion FSM 节点数组位置为 `NodeIndex 4281-4284`。它们不是全局 ActionID，也不应直接写成 `tree:get_actions()[4281]`。当前版本同时保留两条解析路径：

1. 从 Node 的 `get_data():get_actions()` 读取 Act10，优先把原始值交给 `tree:get_action(raw_index)`，保留 Static Action 标记。
2. 使用已验证的四向 Action 回退表：前 `9234`、后 `9287`、左 `9251`、右 `9269`。

参考 Lua Mod 的 `Action_gx = 61` 只说明当时 `9173/9226/9190/9208 + 61` 的版本偏移，不能当作永久常量。游戏更新、动作替换 Mod 或动作表重排后，必须重新确认类型和帧字段。

### 11.3 手动判定延长

手动闪身箭斩延长只写入同一次动作的 DamageReflex/Act10 `_EndFrame`，不重新调用原版闪身箭斩入口。每个对象首次发现时缓存原始结束帧，目标值为“原始结束帧 + 设置的延后 Motion 帧”；关闭功能、切换 Motion FSM Tree 或重载脚本时恢复原值。当前默认延后 `12` 帧，测试时调到 `60` 代表 Motion 帧而非毫秒。

四向 Act10 扫描结果达到 `4/4` 时，说明四个方向都有可写目标。关闭延长后同一提前量恢复原版受击，说明改动作用在成功判定窗口，而不是再次释放动作。

### 11.4 自动 GP 与手动路径分离

自动 GP 走 `snow.player.PlayerQuestBase.checkCalcDamage_DamageSide`：确认接收者为主玩家、武器类型为 `13`、原版伤害流程仍为可接管状态，并通过 `BehaviorTree:setCurrentNode(...)` 进入原版闪身箭斩节点。pending 计时只用来确认是否进入 `452/456`，不会把确认事件当作第二次动作请求。

手动延长不依赖自动入口，也不依赖 `checkDamageReflexNoDamageHitEnable(...)` 必须被调用。后者在当前弓路径中可以保持 `0` 次；实际受击应以 DamageSide 的伤害事件、攻击来源和返回值为准。

### 11.4.1 最终自动 GP 根因：同一攻击链的二次结算（2026-09-06）

最终回归确认自动 GP 已生效，并且不会在闪身箭斩动作中再次发动。关键修复不是
继续扩大周期锁，而是处理同一次怪物命中在相邻帧进入两次
`checkCalcDamage_DamageSide` 的情况：

- 第一次回调处于 `Bank 100 / Motion 107`，提交一次原版闪身箭斩入口，原始伤害
  流程为 `0`，随后节点切换到运行时生成的入口节点。
- 第二次回调仍来自同一攻击链，动作确认 `Motion 452/456` 尚未出现；旧逻辑会
  放行这次回调，角色随后进入 `Bank 1 / Motion 15/16` 受击动作。
- `Motion 452/456` 是动作真正进入后的确认值，不能用请求接口 `pcall` 成功代替。

当前实现增加 `AUTO_CHAIN_PROTECT_FRAMES = 3`：首次回调提交入口后，保护窗口内的
重复回调只拦截同一攻击链，不重新提交动作；只有看到 `452/456` 后才启动周期锁。
这解释了此前“最近触发显示成功但实际被击中”和“周期锁拒绝原因反复出现”的组合
现象，也确定了后续维护要区分：入口等待、同链保护、动作确认、动作周期锁四种状态。

### 11.5 采集结果和诊断解释

- 第三轮采集确认了弓 `13`、Bank `100`、四向 Motion 变化，以及怪物对象 `em131_00` 的 `EmHitAttackShapeData`/`DummyHitAttackShapeData` 受击。
- 采集时“GP 成功”标记有一部分是在后续射箭或收弓动作中点击，只能作为人工标记，不能单独证明成功窗口。
- `反射动作 / 成功条件 = 0 / 0` 只表示诊断 Hook 没看到候选反射入口；它不等于四向 Action 没有被修改。应同时检查 `Motion FSM Act10 目标 / 已修改` 和 `已知 Action 目标 / 已修改`。
- “最近 Motion FSM 目标”曾固定显示“右”，原因是静态扫描最后一项覆盖了摘要；当前代码改为显示四向汇总和目标计数。

### 11.6 联机兼容

联机兼容默认开启，多人检测默认开启，自动 GP/自动闪身箭斩默认关闭。集会所属于在线会话，但“多人任务（任务中）”只有在任务状态有效且玩家数/多人信号成立时才显示“是”。

自动入口过滤顺序为：主玩家接收者 -> `OwnerType == 1` -> `EmHitAttack`/`DummyHitAttack` -> 有对象时匹配 `em###`。多人同步时 `AttackObject` 为空是正常情况，不能单独按空对象丢弃；手动判定沿原版路径，不被联机过滤开关屏蔽。

### 11.7 维护边界

- 只把 `BowAssist/reframework/autorun/BowAssist.lua` 作为安装源码；`analysis/raw` 的动作文件仅供版本适配。
- 不把 `弓.zip`、`dinput8.dll`、`treeToolkit` 或游戏配置同步为发布内容。
- 出现 `0/0`、节点未探测或启动卡顿时，先停用大规模扫描和动作替换 Mod，再用已知 Action 回退表验证；不要把参考 Mod 原样合并进主脚本。

## 12. 测试与部署清单

### 测试

1. 确认弓运行时武器类型为 `13`，Bank 和 Motion 显示正常。
2. 分别进入四个方向 `202/203/204/205`。
3. 检查四个 Action 的类型、原始 `_EndFrame` 和目标 `_EndFrame`。
4. 分别测试成功、过早、过晚和队友攻击。
5. 单人任务与多人任务各测一次。
6. 退出游戏后保存 JSON 采集，再分析事件顺序。

### 部署

1. 覆盖游戏文件前，先把原文件复制到工作区 `备份/<时间戳>`。
2. 配置文件单独备份，部署脚本时不要重置用户设置。
3. 记录部署前后的 SHA-256。
4. 重启游戏让 REFramework 重新加载 Lua。
5. 出现闪退时先恢复最近一次备份，再根据日志缩小变更范围。

## 13. 参考资料

- [BehaviorTree Toolkits 1.21](https://www.caimogu.cc/post/300678.html)：NodeID、NodeIndex、Action/Condition、GP 帧字段和 Hook 思路。
- `F:\ruanjian\guailiemod\弓\reframework\autorun\g.lua`：弓四向 ActionID 与 `_EndFrame` 直接修改示例。
- `F:\ruanjian\guailiemod\全自动闪身箭斩\reframework\autorun\Auto Dodgebolt.lua`：弓运行时类型 `13`、伤害流程和原版闪身箭斩入口示例。
