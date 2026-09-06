# 弓箭参数增强

这是独立于 `BowAssist.lua` 的运行时参数脚本。它不修改 PAK，不替换游戏根目录文件；将脚本复制到 REFramework 的 `autorun` 目录即可。

## 文件位置

```text
BowAssist/reframework/autorun/BowBalance.lua
```

安装到游戏根目录后的位置：

```text
MonsterHunterRise\reframework\autorun\BowBalance.lua
```

现有的 `BowAssist.lua` 仍需单独保留，用于自动 GP、闪身箭斩判定和诊断；两个脚本互不覆盖。

## 默认改动

- 一蓄、二蓄：默认关闭修改，数值保留原版（启用后可单独调节）
- 三蓄物理倍率：`1.5x`
- 四蓄物理倍率：`1.7x`
- 蓄力耐力消耗：原值 `0.5x`
- 箭强化时间：`30` 分钟
- 刚力挽弓时间：`30` 分钟
- 会心起始距离：原值 `75%`，更近开始进入会心区
- 会心结束距离：原值 `125%`，上限不超过最大射程
- 每个 Arrow UserData 的最大射程：`100`
- 距离减伤倍率：`50%`（会心区倍率不改）
- 普通射击与蓄力射击动作速度：`200%`，只匹配
  `BowCreateShellNormal`、`BowCreateShellBelow1st/2nd/3rd` 及其瓶种变体
  的 Motion FSM Action
- 刚连射动作速度：`140%`，单独覆盖参考 Mod 已验证的 Action `9439` 和 `9729`
- 刚射、刚连射、刚射绝、刚连射绝均属于白名单；对应类型分别为
  `BowCreateShellPower`、`BowCreateShellRapidPower`、`BowCreateShellPowerStun`、
  `BowCreateShellRapidPowerStun`
- 刚射派生窗口：普通刚射 `42` 帧、刚连射 `48` 帧，写入原版 Transition
  Condition 的 `StartFrame`。这只提前可输入时机，不改变动画速度

时间按游戏 60 Hz 内部帧换算：分钟值乘以 `60*60`，界面和配置上限均为 30 分钟。

## 界面

进入 REFramework 的 Script Generated UI，打开“弓箭参数增强”。可以单独关闭倍率、耐力、Buff、最大射程、会心距离和箭速。修改配置后脚本会先恢复缓存的原版值，再按新设置重新写入。

“蓄力倍率修改”是一个总开关，统一控制一蓄、二蓄、三蓄和四蓄四项倍率；
“最大射程”和“会心距离”分别是独立开关，关闭其中一项不会影响另一项。

“恢复原版参数”按钮只恢复当前运行时对象；重启游戏后也会重新读取原始数据。

## 说明

“普通射击动作速度”使用 Motion FSM 的动作树，并且只接受上述六类射击族；
`BowAdjustArrowAttackHitData` 单独出现时不再作为速度目标。`9439/9729` 作为
“刚连射动作速度”单独处理。瞄准、收弓、闪身箭斩、滑翔/龙之箭、瓶子切换和
其它过渡动作均不写入。参考 Mod 的四个派生条件为 `7127/7263/7139/7275`，
分别使用普通 `42` 帧和刚连射 `48` 帧。
之前版本扫描了玩家 BHVT，且只写 `v5_Speed`，因此界面显示已修改但实际射击间隔没有变化。
箭矢飞行速度字段 `PlayerUserDataBowArrow._Speed` 保持原版，不会被本脚本写入。
若当前版本没有暴露可写的 `set_Speed`，界面会显示未找到并保持原版速度。
4.00x 会明显压缩动作和输入节奏，推荐先用普通射击 2.00x、刚连射 1.40x，
再逐级增加；若仍有接不上，优先提高对应的派生帧，而不是继续提高速度。

脚本只在运行时武器类型为 `13` 时生效，切换到其它武器会恢复原值。它不会把参数写回 PAK，也不会修改游戏安装文件。
