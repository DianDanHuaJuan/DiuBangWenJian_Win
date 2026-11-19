#Requires -Version 5.1
<#
.SYNOPSIS
  校验 Windows Release 目录是否满足分发/安装包要求。
#>
[CmdletBinding()]
param(
    [string]$ReleaseDir = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
if ([string]::IsNullOrWhiteSpace($ReleaseDir)) {
    $ReleaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
}
$ReleaseDir = (Resolve-Path -LiteralPath $ReleaseDir).Path

$requiredFiles = @(
    'diubangwenjian.exe',
    'flutter_windows.dll',
    'libmpv-2.dll',
    'ffmpeg.exe',
    'app_icon.ico',
    'vcruntime140.dll',
    'vcruntime140_1.dll',
    'msvcp140.dll',
    'data\app.so',
    'data\icudtl.dat'
)

$requiredPlugins = @(
    'file_selector_windows_plugin.dll',
    'window_manager_plugin.dll',
    'system_tray_plugin.dll'
)

Write-Host "校验 Release 目录: $ReleaseDir"

$failures = @()
foreach ($item in ($requiredFiles + $requiredPlugins)) {
    $path = Join-Path $ReleaseDir $item
    if (Test-Path -LiteralPath $path) {
        Write-Host "  OK  $item"
    } else {
        Write-Host "  MISSING  $item"
        $failures += $item
    }
}

$legacyRedist = Join-Path $ReleaseDir 'vc_redist.x64.exe'
if (Test-Path -LiteralPath $legacyRedist) {
    Write-Host '  FAIL  vc_redist.x64.exe 不应出现在 Release 目录'
    throw 'Release 目录包含 vc_redist.x64.exe'
}

if ($failures.Count -gt 0) {
    Write-Error "校验失败，缺少 $($failures.Count) 个文件。"
}

$totalMb = (
    Get-ChildItem -LiteralPath $ReleaseDir -Recurse -File |
    Measure-Object -Property Length -Sum
).Sum / 1MB
Write-Host ("校验通过。总大小约 {0:N1} MB。" -f $totalMb)
