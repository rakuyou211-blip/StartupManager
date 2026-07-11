# build-release.ps1
# 配布用ZIPを作成する (GitHub Releases / オフライン持ち込み用)。
# バックアップや個人設定 (Backups/, settings.json) は含めない。
# 使い方: powershell -NoProfile -ExecutionPolicy Bypass -File build-release.ps1

param([string]$OutDir = $PSScriptRoot)

$ErrorActionPreference = 'Stop'

$files = @(
    'StartupManager.ps1'
    'StartupManager.bat'
    'StartupManager.command'
    'README.md'
    'CHANGELOG.md'
    'LICENSE'
)

$m = Select-String -Path (Join-Path $PSScriptRoot 'StartupManager.ps1') -Pattern "Version = '([\d.]+)'"
$ver = $m.Matches[0].Groups[1].Value
$zip = Join-Path $OutDir "StartupManager_v$ver.zip"

$paths = $files | ForEach-Object {
    $p = Join-Path $PSScriptRoot $_
    if (-not (Test-Path $p)) { throw "ファイルがありません: $p" }
    $p
}

Compress-Archive -Path $paths -DestinationPath $zip -Force
Write-Output "作成しました: $zip"
Write-Output "注意: ZIP経由ではmacOS側の実行権限が消えるため、README記載のとおり"
Write-Output "      chmod +x StartupManager.command が必要になる場合があります。"
