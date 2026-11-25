# 战争雷霆离线版 · 对局/机库涂装修复（0.9.0 / 2.59.0.92）

> 让玩家自己选中的涂装在**机库**和**对局出生**时都真正生效，并让迷彩磨损/缩放/旋转的调节
> 能本地持久化。纯脚本层修复，**只替换 `gui.vromfs.bin`，不碰 `aces.exe`**。

---

## 这是什么

WOP 0.9.0（客户端 2.59.0.92）离线版里，自定义界面选的涂装只对 AI 生效，玩家自己永远是默认皮；
坦克迷彩的三个滑条退出界面就回默认值。原因是原版把"选了哪套皮"和"迷彩参数"都当成
**在线账号设置**存在服务器上，而离线版没有服务器。

本仓库把这部分状态改到本地存档，并把选择重新推送给机库渲染器与实际出生请求。

## 为什么不直接用 0.9.5 的包

| 检查项 | 0.9.5 包 | 本项目目标 |
|---|---|---|
| `aces.exe` FileVersion | 2.61.0.11 | **2.59.0.92** |
| `aces.exe` 大小 | 154,334,208 B | **131,576,320 B** |
| PE 注入节 | `.wtdecor/.wtmods/.wtrplay/.wtbomb/.wtrspn/.wtstate/.wtcode` | `.wtcrew/.wthud/.wtdecor/.wtmods/.wtscout/.wtscst/.wtrplay` |
| `gui.vromfs.bin` 条目数 | 3252 | 3133 |

0.9.5 的 GUI 脚本会调用 2.59 客户端里不存在的原生符号（`modeRules.eventId == "great_war"`
一整套 event loaner、`combat.rememberAirBombingLoadout`、`worldBuilder.resolveFleetSpawn` 等），
硬装上去是启动即黑屏。本仓库把那部分**真正解决问题的逻辑**重新实现到 2.59 的脚本源码上，
不包含任何 exe 补丁。

## 修复清单（7 个脚本 / 1 个新增文件）

| # | 修复 | 文件 | 根因 |
|---|---|---|---|
| 1 | 出生请求把皮肤同时写到顶层 `skin` | `scripts/offline/battle.nut` | 原生 `changeUnit` 解析器读顶层 `skin`，`props.skin` 只在任务 actor 那条路径生效 → AI 有皮、玩家没有 |
| 2 | 选中皮肤记本地 | `scripts/customization/skins.nut` | 原厂皮/自定义皮不在 `ownedSkins` 里，后端 `set_skin` 会以 `This skin is not owned for the vehicle` 拒收 |
| 3 | 机库重新推送皮肤给渲染器 | `scripts/customization/skins.nut`、`scripts/hangarmodelloadmanager.nut` | `set_last_skin` 只记住"选了哪套"，新加载的模型仍停在默认涂装，需再 `apply_skin` |
| 4 | 迷彩磨损/缩放/旋转本地持久化 | **新增** `scripts/offline/camouflage.nut`、`scripts/customization/customizationwnd.nut` | 三项原本存服务器，离线版退出界面即回默认 |
| 5 | 原厂皮肤判定为可用 | `scripts/offline/profile.nut` | `player_have_skin` 只查 `ownedSkins`，载具自带的皮被判"没有" |
| 6 | 贴花槽按当前载具算 + 高级槽认本地改装 | `scripts/offline/decorations.nut` | 只看 `PremiumAccount` entitlement（离线账号永远没有），3/4 号高级槽恒灰 |
| 7 | `getLastSkin` 空载具防御 | `scripts/customization/skins.nut` | `getAircraftByName()` 可能返回 null，旧代码直接 `.isUsable()` 会抛异常 |

## 安装

1. 关闭游戏。
2. 把 Release 里的 `BattleSkinFix-0.9.0.zip` 解压到**游戏根目录**（能看到 `WarThunderOffline.exe` 的那一层）。
3. 右键 `install.ps1` → 使用 PowerShell 运行。
   没有该菜单时，在文件夹空白处 Shift+右键 → 在此处打开 PowerShell 窗口，执行：
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\install.ps1
   ```
4. 仍然用原来的 `WarThunderOffline.exe` 启动。

安装脚本会：
- 校验 `client\win64\aces.exe` 的 SHA-256 是否为 2.59.0.92 那一版（不匹配直接中止，`-Force` 可跳过）；
- 把原版 `client\gui.vromfs.bin` 与 `data\client-build.json` 备份到 `work\battleskin-backup\`（只备份第一次）；
- 替换 `gui.vromfs.bin`，并同步改写 `data\client-build.json` 的 `guiSHA256`（启动器按此哈希校验，不改会拒绝启动）。

## 卸载

右键 `uninstall.ps1` → 使用 PowerShell 运行，从 `work\battleskin-backup\` 还原。

## 怎么确认生效

进自定义界面选一套非默认涂装，然后：

- 机库模型应立刻换成那套涂装；
- 打一局，出生后自己的载具是那套涂装；
- 退出游戏再进来，自定义界面里仍是你选的那套（不是回默认）；
- 拉迷彩磨损/缩放/旋转滑条，退出自定义界面再进，数值还在。

## 已验证 / 未验证

**已验证（本地静态 + 归档级）**
- 打包回读：3134 个条目逐个 SHA-1 与源码树一致，路径小写、原生二分查找排序正确。
- `Assert-FreeNotice` 对成品归档校验通过（免费声明仍在，启动器不会拒绝启动）。
- 相对当前已安装归档的差异：**1 个新增 + 6 个修改**，`aces.exe` 未动。
- `tools/lint_patch.py`：7 个改动文件全部通过（无 `var`、无 DAS 风格转换函数、括号配平、`%` 路径存在、导出符号已定义）。
- `install.ps1` / `uninstall.ps1` 用 Windows PowerShell 5.1 做过语法检查（UTF-8 with BOM）。
- 安装 / 重复安装 / 卸载在临时游戏根目录里真跑过三遍。

**未验证（需实机）**
- 进游戏后涂装是否真的生效——需要启动器（管理员 + WFP 过滤规则），无法自动化。
- 第 1 条在 **2.59** 的原生解析器里是否被读取：2.61 的二进制能找到 `skin` 内联字符串，2.59 里找不到。
  写入未知字段是安全的（解析器会忽略），所以保留；若实测"出生后仍是默认涂装"，
  说明起作用的是第 2/3/5 条（机库与皮肤可用性），需改走
  `unit_spawn_and_route.das` 的 `wtoffline_place_initialized_replacement_es` 给已生成 actor 补 `props.skin`。

## 重新构建

```
python tools\unpack_vromfs.py <原版 gui.vromfs.bin> <解包目录>
# 把 source\ 下的文件覆盖到解包目录对应位置，然后：
python tools\pack_gui.py <源码树> build\gui.vromfs.bin
python tools\build_dist.py
python tools\make_zip.py
```

改完 `source/` 后，`install.ps1` 顶部硬编码的 `$newGuiHash` 必须手动更新，否则安装脚本会自校验失败。

## 目录结构

```
source/scripts/...        7 个改动脚本（相对 gui.vromfs.bin 根的路径）
tools/                    解包 / 打包 / lint / 组包 / 压 ZIP
dist/                     安装脚本 + 清单 + 玩家说明
```

## 与 AI 补丁的关系

本仓库**只管涂装与迷彩本地化**。陆战/空战 AI 行为、票数机制、地图池等改动在另一个仓库
[`warthunder-offline-patch`](https://github.com/dellzou/warthunder-offline-patch)。
两者的 `gui.vromfs.bin` 不可混装——都以"当前已安装归档"为基线各自替换。

## 许可

仅供个人在本地离线环境使用。游戏资源版权归 Gaijin Entertainment 所有，本仓库只分发自己编写的脚本。
