#Requires -Version 5.1
# Build single-file KVM-Tool-Setup.exe
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
if (-not (Test-Path (Join-Path $Root 'KVM-Tool-UI.exe'))) {
    $Root = 'd:\Project\Project\KVM'
}
$Build = Join-Path $Root 'build'
$PayloadDir = Join-Path $Build 'payload'
$Zip = Join-Path $Build 'kvm-tool-payload.zip'
$SetupPs1 = Join-Path $Build 'kvm-setup.ps1'
$OutExe = Join-Path $Root 'KVM-Tool-Setup.exe'
$Ps2Exe = Join-Path $Build 'ps2exe.ps1'

Write-Host "Root = $Root"

# refresh payload
if (Test-Path $PayloadDir) { Remove-Item $PayloadDir -Recurse -Force }
New-Item -ItemType Directory -Path (Join-Path $PayloadDir 'vendor') -Force | Out-Null

$copyFiles = @(
    'KVM-Tool-UI.exe',
    'kvm-settings.ps1',
    'kvm-java.ps1',
    'kvm-tool-ui.ps1',
    'open-kvm.ps1',
    'patch-stunnel.ps1',
    'kvm-tool.ps1',
    'kvm.md'
)
foreach ($f in $copyFiles) {
    $src = Join-Path $Root $f
    if (-not (Test-Path -LiteralPath $src)) { throw "Missing $src" }
    Copy-Item -LiteralPath $src -Destination (Join-Path $PayloadDir $f) -Force
}

# launcher bat (ASCII name + Chinese name)
$bat = @"
@echo off
chcp 65001 >nul
cd /d "%~dp0"
if exist "%~dp0KVM-Tool-UI.exe" (
  start "" "%~dp0KVM-Tool-UI.exe"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0kvm-tool-ui.ps1"
)
"@
[System.IO.File]::WriteAllText((Join-Path $PayloadDir 'Start-KVM-Tool.bat'), $bat, [Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText((Join-Path $PayloadDir '启动KVM工具.bat'), $bat, [Text.UTF8Encoding]::new($true))

$jre = Join-Path $Root 'vendor\jre-8u51-windows-i586.exe'
if (-not (Test-Path $jre)) { throw "Missing Java installer: $jre" }
Copy-Item $jre (Join-Path $PayloadDir 'vendor\jre-8u51-windows-i586.exe') -Force
$readme = Join-Path $Root 'vendor\README.txt'
if (Test-Path $readme) { Copy-Item $readme (Join-Path $PayloadDir 'vendor\README.txt') -Force }

if (Test-Path $Zip) { Remove-Item $Zip -Force }
Compress-Archive -Path (Join-Path $PayloadDir '*') -DestinationPath $Zip -CompressionLevel Optimal -Force
Write-Host ("Payload zip: {0:N1} MB" -f ((Get-Item $Zip).Length / 1MB))

. $Ps2Exe
if (Test-Path $OutExe) {
    Get-Process | Where-Object { $_.Path -eq $OutExe } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 1
    Remove-Item $OutExe -Force -ErrorAction SilentlyContinue
}

Invoke-ps2exe `
    -inputFile $SetupPs1 `
    -outputFile $OutExe `
    -noConsole `
    -STA `
    -title 'KVM Tool Setup' `
    -product 'KVM-Tool-Setup' `
    -version '1.2.0.0' `
    -embedFiles @{ '%TEMP%\kvm-tool-payload.zip' = $Zip }

if (-not (Test-Path $OutExe)) { throw 'Setup exe not created' }
Write-Host ("OK: {0} ({1:N1} MB)" -f $OutExe, ((Get-Item $OutExe).Length / 1MB))
