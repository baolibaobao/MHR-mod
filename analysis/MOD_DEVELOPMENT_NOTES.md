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

多人任务中攻击对象可能为空，空对象需要结合 OwnerType、攻击类型和任务状态判断，避免直接归类为队友。自动功能默认关闭，联机兼容模式和多人任务检测默认开启，避免测试时误触发。

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

自动 GP 可以通过 `BehaviorTree:setCurrentNode(...)` 进入原版闪身箭斩，但这只能解决自动触发入口；手动成功窗口仍需要修改真正的 DamageReflex Action 或运行时反射对象。

### 不缓存动作切换前状态

伤害 Hook 执行时，MotionID 可能已经从 GP 动作切换到受击或后续动作。需要缓存上一动作、Bank 和帧数，单独读取 Hook 回调瞬间的状态不够可靠。

## 10. 测试与部署清单

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

## 11. 参考资料

- [BehaviorTree Toolkits 1.21](https://www.caimogu.cc/post/300678.html)：NodeID、NodeIndex、Action/Condition、GP 帧字段和 Hook 思路。
- `F:\ruanjian\guailiemod\弓\reframework\autorun\g.lua`：弓四向 ActionID 与 `_EndFrame` 直接修改示例。
- `F:\ruanjian\guailiemod\全自动闪身箭斩\reframework\autorun\Auto Dodgebolt.lua`：弓运行时类型 `13`、伤害流程和原版闪身箭斩入口示例。
