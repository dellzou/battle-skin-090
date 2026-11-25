# 对局/机库涂装修复 —— 0.9.0 (2.59.0.92) 专用安装脚本
#
# 这个包只替换 client\gui.vromfs.bin，不碰 aces.exe。
# 0.9.5 那个包里附带的 aces-patched.exe 是 2.61.0.11 的二进制，装到 2.59 客户端上
# 会因为内部结构不匹配直接不启动，所以这里完全不使用它。
param([switch]$Force)
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$expectedAces = 'e5b7ca9767a8e9ede97da213202c334b2e70ceacca7a996295607a1c38b79eeb'
$newGuiHash   = '6e8ffcf24ebba78d427760099d016b1b1521b1a8d0d676763ac6c9693ed520e7'

$newGui = Join-Path $root 'files\gui.vromfs.bin'
$aces   = Join-Path $root 'client\win64\aces.exe'
$gui    = Join-Path $root 'client\gui.vromfs.bin'
$build  = Join-Path $root 'data\client-build.json'
$backup = Join-Path $root 'work\battleskin-backup'

function Get-Sha([string]$path) { return (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLower() }
function Write-JsonFile([string]$path, $object) {
  $text = $object | ConvertTo-Json -Depth 12
  [IO.File]::WriteAllText($path, $text, [Text.UTF8Encoding]::new($false))
}

Write-Output '=== 对局涂装修复 (0.9.0 / 2.59.0.92) ==='

if (-not (Test-Path -LiteralPath (Join-Path $root 'WarThunderOffline.exe'))) {
  throw '请把压缩包解压到游戏根目录（能看到 WarThunderOffline.exe 的那个文件夹）再运行本脚本。'
}
foreach ($file in @($newGui, $aces, $gui, $build)) {
  if (-not (Test-Path -LiteralPath $file)) { throw "缺少文件: $file" }
}
if (Get-Process aces -ErrorAction SilentlyContinue) { throw '请先关闭游戏再安装。' }

# 版本校验：aces.exe 必须是 2.59.0.92 这一版，否则补丁的 GUI 与客户端不匹配。
$acesHash = Get-Sha $aces
if ($acesHash -ne $expectedAces) {
  if (-not $Force) {
    throw ("版本不匹配。你的 aces.exe 是 {0}，本补丁需要 {1}。`n" +
           "要么换回 0.9.0 客户端，要么确认后加 -Force 强制安装（不推荐）。") -f $acesHash, $expectedAces
  }
  Write-Output '警告：已用 -Force 跳过版本校验。'
}

# 备份原文件（只备份第一次，重复安装不会覆盖掉真正的原版）
New-Item -ItemType Directory -Path $backup -Force | Out-Null
if (-not (Test-Path -LiteralPath (Join-Path $backup 'gui.vromfs.bin'))) {
  Copy-Item -LiteralPath $gui -Destination (Join-Path $backup 'gui.vromfs.bin')
  Copy-Item -LiteralPath $build -Destination (Join-Path $backup 'client-build.json')
  Write-Output "已备份原文件到 $backup"
} else {
  Write-Output "原文件备份已存在，沿用: $backup"
}

# 换入新的 GUI 归档
Copy-Item -LiteralPath $newGui -Destination $gui -Force
if ((Get-Sha $gui) -ne $newGuiHash) { throw 'GUI 复制后哈希校验失败，安装中止。' }

# 启动器会按 data\client-build.json 里的哈希校验资源，这里必须同步改掉。
$document = Get-Content -Raw -LiteralPath $build | ConvertFrom-Json
$document | Add-Member -NotePropertyName 'guiSHA256' -NotePropertyValue $newGuiHash.ToUpperInvariant() -Force
Write-JsonFile $build $document

Write-Output ''
Write-Output '安装完成。'
Write-Output "  已替换: $gui"
Write-Output "  已更新: $build"
Write-Output ''
Write-Output '用原来的 WarThunderOffline.exe 启动即可，不需要额外启动器。'
Write-Output '卸载：右键 uninstall.ps1 -> 使用 PowerShell 运行。'
