对局涂装修复 —— 0.9.0 (2.59.0.92) 专用

【这个包解决什么】
对局里和机库里，玩家自己选中的涂装不生效（永远显示默认涂装），
坦克迷彩的磨损/缩放/旋转调节完退出就回到默认值。

【为什么不直接用 0.9.5 那个包】
0.9.5 包里带的是 2.61.0.11 版的 aces-patched.exe 和同版本的 gui.vromfs.bin。
你的客户端是 2.59.0.92，exe 内部结构完全不同，装上去游戏根本起不来；
它的 gui.vromfs.bin 也是 2.61 的脚本，和 2.59 的原生接口对不上。
所以本包不包含任何 exe 补丁，只替换 gui.vromfs.bin（纯脚本层修复），
并且是按 2.59.0.92 的脚本源码重新打包的。

【安装】
1. 关闭游戏。
2. 把压缩包解压到游戏根目录（能看到 WarThunderOffline.exe 的那个文件夹），
   让 install.ps1、uninstall.ps1、files\ 和 WarThunderOffline.exe 在同一层。
3. 右键 install.ps1 -> "使用 PowerShell 运行"。
   如果右键没有这个菜单：在文件夹空白处 Shift+右键 -> "在此处打开 PowerShell 窗口"，执行
     powershell -ExecutionPolicy Bypass -File .\install.ps1
4. 看到"安装完成"就装好了。仍然用原来的 WarThunderOffline.exe 启动。

【安装脚本会做什么】
- 校验 client\win64\aces.exe 的 SHA-256 是否为 2.59.0.92 那一版（不是你这一版会直接中止）。
- 把原版 client\gui.vromfs.bin 和 data\client-build.json 备份到 work\battleskin-backup\
  （只备份第一次，重复安装不会把备份覆盖成补丁版）。
- 用新的 gui.vromfs.bin 替换，并同步改写 data\client-build.json 里的 guiSHA256
  ——启动器会按这个哈希校验资源，不改游戏会拒绝启动。

【怎么确认生效】
进自定义界面选一套非默认涂装，然后：
- 机库模型应该立刻换成那套涂装；
- 打一局，出生后自己的载具是那套涂装；
- 退出游戏再进来，自定义界面里仍然是你选的那套（而不是回默认）；
- 拉一下迷彩磨损/缩放/旋转滑条，退出自定义界面再进，数值还在。

【卸载】
右键 uninstall.ps1 -> 使用 PowerShell 运行。
会用 work\battleskin-backup\ 里的备份还原 GUI 和 client-build.json。

【出问题怎么办】
把 client\.game_logs\ 下最新的 .clog 保留下来（别删），
再说明一下是"进不去游戏/黑屏"还是"涂装还是不对"。

【包里改了什么】
新增：scripts\offline\camouflage.nut（迷彩参数本地持久化）
修改：scripts\customization\skins.nut             选中皮肤记本地 + 机库重新推送皮肤给渲染器
      scripts\customization\customizationwnd.nut   迷彩滑条写本地 + 退出时落盘
      scripts\hangarmodelloadmanager.nut           模型加载完成后回灌皮肤/迷彩/贴花槽
      scripts\offline\battle.nut                   出生请求把皮肤写到顶层 skin 字段
      scripts\offline\decorations.nut              贴花槽按当前载具算，高级槽认本地改装
      scripts\offline\profile.nut                  原厂皮肤也判定为"可用"
