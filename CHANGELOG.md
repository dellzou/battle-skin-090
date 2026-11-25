# Changelog

## 0.9.0 — 2026-11-25

首个版本。针对 WOP 0.9.0 / 客户端 **2.59.0.92** 的涂装与迷彩持久化修复，
只替换 `client/gui.vromfs.bin`，不含任何 `aces.exe` 补丁。

### 新增
- `scripts/offline/camouflage.nut`：迷彩磨损 / 缩放 / 旋转三项参数的本地持久化。
  按 `unit/skin` 存进本地账号设置，机库模型加载后回灌；滑条节流 0.4 秒落盘，
  `onDestroy` 强制 flush。

### 修复
- **出生涂装不生效**：`scripts/offline/battle.nut` 把皮肤同时写到请求顶层 `skin` 字段。
  原生 `changeUnit` 解析器读的是顶层 `skin`（日志 `Unit::changeUnitAsyncImpl … skin='%s'`），
  `props.skin` 只在任务 actor 路径生效，导致 AI 有涂装、玩家永远默认皮。
- **选了皮肤存不下来**：`scripts/customization/skins.nut` 改为优先读写本地
  `offlineSkins/<unit>`，后端 `set_skin` 仅在"已购皮肤包 / default"时同步。
  原厂皮与自定义皮不在 `ownedSkins` 里，原先会被后端以
  `This skin is not owned for the vehicle` 拒收。
- **机库不换皮**：`skins.nut` 新增 `applySavedSkinToHangar()`，`scripts/hangarmodelloadmanager.nut`
  在模型加载完成后调用，把 `set_last_skin` 记住的选择真正推给渲染器。
- **原厂皮肤被判不可用**：`scripts/offline/profile.nut` 的 `player_have_skin` 补上
  "`config/skins.blk` 里登记过"和"载具 blk 里有 `skin` 块"两条原生来源。
- **高级贴花槽恒灰**：`scripts/offline/decorations.nut` 由 `PremiumAccount` entitlement
  改为看本地改装树 `allowPremDecals`；槽数按显式传入的当前载具计算。
- **`getLastSkin` 空指针**：`getAircraftByName()` 返回 null 时的防御。
- **`setCurSkinToHangar` 误重置换皮**：只在确实有已选皮肤时才 `set_last_skin`。

### 备注
- 目标客户端固定为 2.59.0.92（`aces.exe` SHA-256 `e5b7ca97…79eeb`），
  安装脚本会校验，不匹配直接中止。
- 未包含 0.9.5 包里那些 2.61 专属功能（Great War 步兵事件、舰队出生区、
  观战比分板、空战票数通道重构等），它们依赖 2.61 的原生符号，2.59 上无法移植。
