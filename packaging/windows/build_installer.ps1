#Requires -Version 5.1
<#
.SYNOPSIS
  构建铥棒文件 Windows Release 并编译 Inno Setup 安装包。

.PARAMETER SkipFlutterBuild
  跳过 flutter build，仅校验产物并编译安装包。

.PARAMETER SkipInstaller
  仅执行 flutter build 与产物校验，不调用 ISCC。
#>
[CmdletBinding()]
param(
    [switch]$SkipFlutterBuild,
    [switch]$SkipInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
Set-Location $repoRoot

function Get-PubspecVersion {
    $pubspecPath = Join-Path $repoRoot 'pubspec.yaml'
    $content = Get-Content -Path $pubspecPath -Raw
    if ($content -match '(?m)^version:\s*([0-9]+\.[0-9]+\.[0-9]+\+[0-9]+)\s*$') {
        return $Matches[1]
    }
    throw '无法在 pubspec.yaml 中解析 version 字段。'
}

function Get-IsccPath {
    $candidates = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe"
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Test-ReleaseBundle {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ReleaseDir
    )

    $requiredFiles = @(
        'diubangwenjian.exe',
        'flutter_windows.dll',
        'ffmpeg.exe',
        'app_icon.ico',
        'vcruntime140.dll',
        'vcruntime140_1.dll',
        'msvcp140.dll',
        'data\app.so',
        'data\icudtl.dat',
        'data\flutter_assets\AssetManifest.bin'
    )

    $missing = @()
    foreach ($relativePath in $requiredFiles) {
        $fullPath = Join-Path $ReleaseDir $relativePath
        if (-not (Test-Path -LiteralPath $fullPath)) {
            $missing += $relativePath
        }
    }

    $legacyRedist = Join-Path $ReleaseDir 'vc_redist.x64.exe'
    if (Test-Path -LiteralPath $legacyRedist) {
        throw 'Release 目录仍包含 vc_redist.x64.exe，请重新运行 collect_vc_runtime.ps1 或清理后重试。'
    }

    if ($missing.Count -gt 0) {
        throw "Release 产物不完整，缺少: $($missing -join ', ')"
    }

    $totalBytes = (
        Get-ChildItem -LiteralPath $ReleaseDir -Recurse -File |
        Measure-Object -Property Length -Sum
    ).Sum
    Write-Host "Release 产物校验通过。目录: $ReleaseDir"
    Write-Host ("总大小: {0:N1} MB" -f ($totalBytes / 1MB))
}

$versionFull = Get-PubspecVersion
$version = $versionFull.Split('+')[0]

$ffmpegSource = Join-Path $repoRoot 'assets\ffmpeg.exe'
$bootstrap = Join-Path $repoRoot 'tool\bootstrap_windows.ps1'
if (Test-Path -LiteralPath $bootstrap) {
    Write-Host 'Bootstrapping Windows build dependencies ...'
    & $bootstrap -RepoRoot $repoRoot
    if ($LASTEXITCODE -ne 0) {
        throw 'Windows 构建依赖引导失败。请运行 .\tool\bootstrap_windows.ps1 后重试。'
    }
} elseif (-not (Test-Path -LiteralPath $ffmpegSource)) {
    throw '缺少 assets\ffmpeg.exe。请先准备 FFmpeg 后再构建。'
}

if (-not $SkipFlutterBuild) {
    $gitSha = 'dev'
    try {
        $gitSha = (git -C $repoRoot rev-parse --short HEAD).Trim()
    } catch {
        Write-Warning '无法读取 git SHA，使用 dev。'
    }
    $buildTime = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')

    Write-Host "构建 Release 版本 $versionFull (sha=$gitSha) ..."
    flutter build windows --release `
        --dart-define=NAS_APP_VERSION=$versionFull `
        --dart-define=NAS_BUILD_SHA=$gitSha `
        --dart-define=NAS_BUILD_TIME=$buildTime
    if ($LASTEXITCODE -ne 0) {
        throw 'flutter build windows --release 失败。'
    }
}

$releaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
if (-not (Test-Path -LiteralPath $releaseDir)) {
    throw "未找到 Release 目录: $releaseDir"
}

# 确保安装目录旁有绿标 ico（托盘 / 快捷方式 IconFilename）
$iconSrc = Join-Path $repoRoot 'windows\runner\resources\app_icon.ico'
$iconDst = Join-Path $releaseDir 'app_icon.ico'
Copy-Item -LiteralPath $iconSrc -Destination $iconDst -Force
Write-Host "已同步 app_icon.ico 到 Release。"

Write-Host '部署 MSVC 运行库 DLL ...'
& (Join-Path $PSScriptRoot 'collect_vc_runtime.ps1') -ReleaseDir $releaseDir -RepoRoot $repoRoot

$noticesSource = Join-Path $repoRoot 'THIRD_PARTY_NOTICES.txt'
if (Test-Path -LiteralPath $noticesSource) {
    Copy-Item -LiteralPath $noticesSource -Destination (Join-Path $releaseDir 'THIRD_PARTY_NOTICES.txt') -Force
}

Test-ReleaseBundle -ReleaseDir $releaseDir

if ($SkipInstaller) {
    Write-Host '已跳过 Inno Setup 编译（-SkipInstaller）。'
    exit 0
}

$iscc = Get-IsccPath
if ($null -eq $iscc) {
    throw @"
未找到 Inno Setup 6（ISCC.exe）。请安装后重试：
  https://jrsoftware.org/isinfo.php
或使用 -SkipInstaller 仅生成 Release 目录。
"@
}

$issPath = Join-Path $PSScriptRoot 'diubangwenjian.iss'
Write-Host "编译安装包 (ISCC) ..."
& $iscc `
    "/DMyAppVersion=$version" `
    "/DMyAppVersionFull=$versionFull" `
    $issPath
if ($LASTEXITCODE -ne 0) {
    throw 'Inno Setup 编译失败。'
}

$outputExe = Join-Path $PSScriptRoot "output\DiuBangWenJian-Setup-$version.exe"
if (Test-Path -LiteralPath $outputExe) {
    $setupSize = (Get-Item -LiteralPath $outputExe).Length
    Write-Host "安装包已生成: $outputExe"
    Write-Host ("安装包大小: {0:N1} MB" -f ($setupSize / 1MB))
} else {
    Write-Warning "ISCC 已退出但未找到预期输出: $outputExe"
}
