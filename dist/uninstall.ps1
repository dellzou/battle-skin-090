# 卸载对局涂装修复，恢复原始的 gui.vromfs.bin 与 data\client-build.json
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$backup = Join-Path $root 'work\battleskin-backup'

if (Get-Process aces -ErrorAction SilentlyContinue) { throw '请先关闭游戏再卸载。' }
if (-not (Test-Path -LiteralPath (Join-Path $backup 'gui.vromfs.bin'))) {
  throw "没有找到备份（$backup\gui.vromfs.bin），无法自动还原。"
}

Copy-Item -LiteralPath (Join-Path $backup 'gui.vromfs.bin') -Destination (Join-Path $root 'client\gui.vromfs.bin') -Force
Copy-Item -LiteralPath (Join-Path $backup 'client-build.json') -Destination (Join-Path $root 'data\client-build.json') -Force

Write-Output '已从备份还原 client\gui.vromfs.bin 和 data\client-build.json。'
Write-Output '备份目录 work\battleskin-backup 保留未删，确认游戏正常后可手动删除。'
