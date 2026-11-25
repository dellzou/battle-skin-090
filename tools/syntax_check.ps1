$ErrorActionPreference = 'Stop'
$dist = Join-Path (Split-Path -Parent $PSScriptRoot) 'battleskin-090\dist'
foreach ($f in @('install.ps1', 'uninstall.ps1')) {
  $path = Join-Path $dist $f
  $text = [IO.File]::ReadAllText($path, [Text.Encoding]::UTF8)
  $errors = $null
  [void][System.Management.Automation.PSParser]::Tokenize($text, [ref]$errors)
  if ($errors.Count) {
    Write-Output "$f ERROR"
    $errors | ForEach-Object { Write-Output ('  ' + $_.Message) }
  } else {
    Write-Output "$f OK"
  }
}
