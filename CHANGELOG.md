# Changelog

## Development notes - 2026-09-04

- 同步弓箭独立 Mod 源码 `BowAssist/reframework/autorun/BowAssist.lua` 及使用说明。
- 归档弓箭第三轮诊断采集 `analysis/captures/BowAssist_capture.json`。
- 归档弓 Bank 100 的 `plf_Bow_100.motlist.528`、`plf_Bow_bank.motbank.3` 原始动作资源，并补充四向 `202/203/204/205`、NodeIndex `4281-4284`、Action `9234/9287/9251/9269` 维护记录。
- 明确弓箭运行时武器类型为 `13`，`Action_gx = 61` 仅为版本偏移；补充 Act10、Static Action、`checkCalcDamage_DamageSide` 和多人空攻击对象的排查结论。
- 本次不新增或同步 Mod 安装包、DLL、工具包和发布 ZIP。

## Development notes - 2026-09-03

- 新增 `analysis/MOD_DEVELOPMENT_NOTES.md`，记录 Motion FSM Tree 获取、`tree:get_actions()[ActionID]` 直接 Action 路线、NodeIndex/NodeID/ActionID 区分、Static Action 标记、DamageReflex 字段、弓四向闪身箭斩 ActionID、Hook 与部署测试陷阱。
- 补充太刀开发记录：自动居合/自动见切入口与成功分支、Motion `307` 上一动作缓存、`9124`/`9125` 判定区别、手动窗口延长、竖直攻击、多人来源过滤、诊断性能、闪退和 Mod 冲突排查。

## 1.0.1 - 2026-09-02

- 修复头部/脚底等纯竖直攻击因水平投影接近零而漏触发自动居合和自动见切的问题。
- 保留原有水平 120 度正面限制；垂直来源攻击按中性水平角 `0` 处理。

## Development data - 2026-08-31

- 归档太刀 `LongSword.motfsm2.43` 与 `LongSword.rcol.20` 原始拆包文件。
- 归档有效运行时拆解和历史 Transition 探针。
- 增加 Motion、Node、Action、Condition 与判定字段维护索引。

## 1.0.0 - 2026-08-27

- 完成自动居合与正面 120 度攻击来源限制。
- 完成自动见切及原版动作入口限制。
- 完成单人/多人伤害来源兼容与队友攻击过滤。
- 完成手动居合判定延长，修复重复释放动作。
- 完成手动见切成功判定延长，使用动作 9124 的 `_EndFrame`。
- 完成中文 REFramework 设置和运行状态界面。
