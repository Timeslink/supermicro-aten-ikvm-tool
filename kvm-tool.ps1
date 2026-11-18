#Requires -Version 5.1
# Supermicro ATEN iKVM: diagnose / BMC time / verify patch / open KVM
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ErrorActionPreference = 'Continue'
try { chcp 65001 | Out-Null } catch {}

# Works for .ps1 and for PS2EXE-compiled .exe
if ($MyInvocation.MyCommand.CommandType -eq 'ExternalScript') {
    $Root = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
} else {
    $Root = Split-Path -Parent -Path ([Environment]::GetCommandLineArgs()[0])
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Get-Location).Path }
}
$CfgPath = Join-Path $Root 'kvm.md'
$PatchScript = Join-Path $Root 'patch-stunnel.ps1'
$OpenScript = Join-Path $Root 'open-kvm.ps1'
$SettingsLib = Join-Path $Root 'kvm-settings.ps1'
if (Test-Path $SettingsLib) { . $SettingsLib }

$script:CertNotBefore = [datetime]'2016-05-19'
$script:CertNotAfter  = [datetime]'2026-05-17'
$script:SafeBmcTime   = if (Get-Command Get-SuggestedBmcTime -ErrorAction SilentlyContinue) {
    Get-SuggestedBmcTime $script:CertNotBefore $script:CertNotAfter
} else {
    [datetime]'2025-01-15 12:00:00'
}
$script:CertSource = 'builtin-default'
$BmcHostDefault = '10.12.45.116'

function Write-Title($t) {
    Write-Host ''
    Write-Host ('=' * 60) -ForegroundColor Cyan
    Write-Host " $t" -ForegroundColor Cyan
    Write-Host ('=' * 60) -ForegroundColor Cyan
}
function Write-Ok($m)   { Write-Host "[OK]  $m" -ForegroundColor Green }
function Write-Warn($m) { Write-Host "[!!]  $m" -ForegroundColor Yellow }
function Write-Bad($m)  { Write-Host "[XX]  $m" -ForegroundColor Red }
function Write-Info($m) { Write-Host "[..]  $m" -ForegroundColor Gray }

function Get-Config {
    if (-not (Test-Path $CfgPath)) { throw "Missing kvm.md in $Root" }
    $raw = Get-Content $CfgPath -Raw -Encoding UTF8
    $user = 'ADMINISTRATOR'
    if ($raw -match 'USER:\s*(\S+)') { $user = $Matches[1] }
    if ($raw -notmatch 'PASS:\s*(\S+)') { throw 'kvm.md missing PASS:' }
    $pass = $Matches[1]
    $hostAddr = $BmcHostDefault
    if ($raw -match 'https?://([0-9.]+)') { $hostAddr = $Matches[1] }
    [pscustomobject]@{ User = $user; Pass = $pass; Host = $hostAddr; Base = "http://$hostAddr" }
}

function New-CookieJar {
    Join-Path $env:TEMP ("kvm_tool_{0}.txt" -f [guid]::NewGuid().ToString('N'))
}

function Invoke-BmcLogin($cfg, $jar) {
    $code = curl.exe -sS -k -m 20 -c $jar -b $jar -o NUL -w "%{http_code}" `
        --data-urlencode "name=$($cfg.User)" --data-urlencode "pwd=$($cfg.Pass)" `
        "$($cfg.Base)/cgi/login.cgi"
    if ($code -ne '200') { throw "Login failed HTTP $code" }
    if (-not (Select-String -Path $jar -Pattern '\tSID\t\S+' -Quiet)) {
        throw 'Login failed: no SID cookie'
    }
}

function Get-BmcDateTime($cfg, $jar) {
    $xml = curl.exe -sS -k -m 15 -b $jar --data 'GET_DATE_TIME.XML=(0,0)' "$($cfg.Base)/cgi/ipmi.cgi"
    $y = [regex]::Match($xml, 'YEAR="(\d+)"').Groups[1].Value
    $mo = [regex]::Match($xml, 'MONTH="(\d+)"').Groups[1].Value
    $d = [regex]::Match($xml, 'DAY="(\d+)"').Groups[1].Value
    $h = [regex]::Match($xml, 'HOUR="(\d+)"').Groups[1].Value
    $mi = [regex]::Match($xml, 'MIN="(\d+)"').Groups[1].Value
    $s = [regex]::Match($xml, 'SEC="(\d+)"').Groups[1].Value
    if (-not $y) { return $null }
    return Get-Date -Year ([int]$y) -Month ([int]$mo) -Day ([int]$d) `
        -Hour ([int]$h) -Minute ([int]$mi) -Second ([int]$s)
}

function Set-BmcDateTime($cfg, $jar, [datetime]$when) {
    $body = "timezone=0&dst_en=0&ntp=off&ntp_server_pri=&ntp_server_2nd=" +
        "&year=$($when.Year)&month=$($when.Month)&day=$($when.Day)" +
        "&hour=$($when.Hour)&min=$($when.Minute)&sec=$($when.Second)"
    return (curl.exe -sS -k -m 20 -b $jar --data $body "$($cfg.Base)/cgi/config_date_time.cgi")
}

function Get-SslStatus($cfg, $jar) {
    $xml = curl.exe -sS -k -m 15 -b $jar --data 'SSL_STATUS.XML=(0,0)' "$($cfg.Base)/cgi/ipmi.cgi"
    [pscustomobject]@{
        ValidFrom  = [regex]::Match($xml, 'VALID_FROM="([^"]*)"').Groups[1].Value
        ValidUntil = [regex]::Match($xml, 'VALID_UNTIL="([^"]*)"').Groups[1].Value
    }
}

function Get-PowerStatus($cfg, $jar) {
    $xml = curl.exe -sS -k -m 15 -b $jar --data 'POWER_INFO.XML=(0,0)' "$($cfg.Base)/cgi/ipmi.cgi"
    [regex]::Match($xml, 'STATUS="([^"]+)"').Groups[1].Value
}

function Test-Port($hostAddr, $port, $timeoutMs = 2000) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $tcp.BeginConnect($hostAddr, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)) { return $false }
        return $tcp.Connected
    } catch { return $false } finally { $tcp.Close() }
}

function Find-Java32 {
    Get-ChildItem 'C:\Program Files (x86)\Java' -Recurse -Filter 'javaws.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
}

function Test-PatcherRunning {
    [bool](Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*patch-stunnel.ps1*' })
}

function Start-Patcher {
    if (-not (Test-Path $PatchScript)) { throw "Missing $PatchScript" }
    if (Test-PatcherRunning) { Write-Ok 'patch-stunnel.ps1 already running'; return }
    Start-Process powershell.exe -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PatchScript
    ) -WindowStyle Minimized
    Start-Sleep 1
    if (Test-PatcherRunning) { Write-Ok 'Started patch-stunnel.ps1 (auto verify=0)' }
    else { Write-Bad 'Failed to start patcher' }
}

function Show-Knowledge {
    Write-Title 'New PC checklist / how it works'
    Write-Host @'
[Device]
  Supermicro X7SB3 / ATEN IPMI - Java iKVM only (no HTML5)

[Two clocks]
  Local Windows time  = your PC clock (stunnel/Java verify)
  BMC time            = IPMI chip clock (BMC checks client cert)
  Guest Windows time  = OS lock-screen time (NOT BMC)

[KVM cert window] (stunnel client.crt / server.crt)
  Valid: 2016-05-19 .. 2026-05-17
  BMC time MUST be inside this window
  Recommended BMC time: 2025-01-15
  Web SSL page 2013-2016 is a DIFFERENT cert - ignore for KVM

[verify]
  Launch Console extracts stunnel.conf with verify=3
  If local date > 2026-05-17, verify=3 fails on your PC
  Fix: run patch-stunnel.ps1 -> verify=0 + soften TLS
  Copy this folder to the new PC and start patcher first

[New PC steps]
  1. Install 32-bit Java 8u51 (REQUIRED; no x64 native lib on this firmware)
     https://archive.org/download/Java_8_update_51/jre-8u51-windows-i586.exe
  2. Copy this whole folder (kvm.md + scripts)
  3. Run 启动KVM工具.bat  or  kvm-tool.ps1
  4. Menu 1 diagnose -> 2 fix BMC time -> 3 patcher -> 4 open
  5. Java Security Warning: accept + Run
  6. Do NOT logout IPMI web after JNLP download (SID inside JNLP)

[Ctrl+Alt+Del]
  Use iKVM Macro / virtual keys, not local keyboard

[Lag FPS 0]
  Common on old ATEN; lower quality in Options or reopen viewer
'@
}

function Invoke-Diagnose {
    Write-Title 'Full diagnose'
    $cfg = Get-Config
    Write-Info "BMC: $($cfg.Host)  user: $($cfg.User)"
    Write-Info ("Local time: {0}" -f (Get-Date))

    Write-Host ''
    Write-Host '--- Ports ---' -ForegroundColor White
    foreach ($p in 80, 443, 5900, 623) {
        if (Test-Port $cfg.Host $p) { Write-Ok "Port $p open" }
        else { Write-Bad "Port $p closed/timeout" }
    }

    Write-Host ''
    Write-Host '--- Java 32-bit + javaws ---' -ForegroundColor White
    $j32 = Find-Java32
    if ($j32) { Write-Ok "javaws: $j32" }
    else {
        Write-Bad '32-bit Java 8 javaws not found'
        Write-Warn 'Install: https://archive.org/download/Java_8_update_51/jre-8u51-windows-i586.exe'
    }
    if (Test-Path 'C:\Program Files\Java') {
        Write-Warn 'Found Program Files\Java (maybe 64-bit). Use (x86) Java for this BMC.'
    }

    Write-Host ''
    Write-Host '--- verify patcher ---' -ForegroundColor White
    if (-not (Test-Path $PatchScript)) { Write-Bad "Missing $PatchScript" }
    elseif (Test-PatcherRunning) { Write-Ok 'patch-stunnel.ps1 running' }
    else { Write-Warn 'Patcher not running (start with menu 3)' }

    Write-Host ''
    Write-Host '--- BMC login / cert window / time ---' -ForegroundColor White
    $jar = New-CookieJar
    try {
        Invoke-BmcLogin $cfg $jar
        Write-Ok 'IPMI login OK'

        if (Get-Command Resolve-KvmCertWindow -ErrorAction SilentlyContinue) {
            $win = Resolve-KvmCertWindow -Cfg $cfg -CookieJar $jar -AllowBmcDownload
            $script:CertNotBefore = [datetime]$win.NotBefore
            $script:CertNotAfter = [datetime]$win.NotAfter
            $script:SafeBmcTime = Get-SuggestedBmcTime $script:CertNotBefore $script:CertNotAfter
            $script:CertSource = [string]$win.Source
            Write-Info ("Cert source: {0} ({1})" -f $win.Source, $win.Detail)
        }
        Write-Info ("KVM cert window: {0:yyyy-MM-dd} .. {1:yyyy-MM-dd}" -f $script:CertNotBefore, $script:CertNotAfter)
        Write-Info ("Suggested BMC time: {0:yyyy-MM-dd HH:mm:ss}" -f $script:SafeBmcTime)

        $bmcNow = Get-BmcDateTime $cfg $jar
        if ($bmcNow) {
            Write-Info ("BMC time now: {0:yyyy-MM-dd HH:mm:ss}" -f $bmcNow)
            if ($bmcNow -ge $script:CertNotBefore -and $bmcNow -le $script:CertNotAfter) {
                Write-Ok 'BMC time is inside KVM cert window'
            } else {
                Write-Bad 'BMC time OUTSIDE KVM cert window -> SSL will fail'
                Write-Warn ("Set to {0:yyyy-MM-dd} via menu 2" -f $script:SafeBmcTime)
            }
        } else { Write-Bad 'Cannot read BMC time' }

        $ssl = Get-SslStatus $cfg $jar
        Write-Info ("Web SSL cert (different): {0} .. {1}" -f $ssl.ValidFrom, $ssl.ValidUntil)

        $pwr = Get-PowerStatus $cfg $jar
        if ($pwr) { Write-Info "Chassis power: $pwr" }

        $code64 = curl.exe -sS -k -m 10 -b $jar -o NUL -w "%{http_code}" `
            "$($cfg.Base)/libwin_x86_64__V1.0.5.jar.pack.gz"
        $code32 = curl.exe -sS -k -m 10 -b $jar -o NUL -w "%{http_code}" `
            "$($cfg.Base)/libwin_x86__V1.0.5.jar.pack.gz"
        if ($code32 -eq '200') { Write-Ok 'Firmware has 32-bit iKVM native lib' }
        else { Write-Bad "32-bit lib HTTP $code32" }
        if ($code64 -eq '200') { Write-Ok 'Firmware has 64-bit lib' }
        else { Write-Warn "No 64-bit lib (HTTP $code64) -> must use 32-bit Java" }
    } catch {
        Write-Bad $_.Exception.Message
    } finally {
        if (Test-Path $jar) {
            curl.exe -sS -k -m 8 -b $jar -o NUL "$($cfg.Base)/cgi/logout.cgi" | Out-Null
            Remove-Item $jar -Force -ErrorAction SilentlyContinue
        }
    }

    Write-Host ''
    Write-Host '--- Local time vs cert (why verify=0) ---' -ForegroundColor White
    $local = Get-Date
    if ($local -gt $script:CertNotAfter) {
        Write-Warn ("Local {0:yyyy-MM-dd} > cert end -> MUST use verify=0 patcher" -f $local)
    } else {
        Write-Ok 'Local time still before cert end; patcher still recommended for TLS options'
    }
}

function Invoke-FixBmcTime {
    Write-Title 'Set BMC time to suggested value'
    $cfg = Get-Config
    Write-Host ("Cert window: {0:yyyy-MM-dd} ~ {1:yyyy-MM-dd} [{2}]" -f $script:CertNotBefore, $script:CertNotAfter, $script:CertSource) -ForegroundColor Gray
    Write-Host ("Will write: {0:yyyy-MM-dd HH:mm:ss}" -f $script:SafeBmcTime) -ForegroundColor Yellow
    $ans = Read-Host 'Confirm write? (Y/N)'
    if ($ans -notmatch '^[Yy]') { Write-Info 'Cancelled'; return }
    $jar = New-CookieJar
    try {
        Invoke-BmcLogin $cfg $jar
        if (Get-Command Resolve-KvmCertWindow -ErrorAction SilentlyContinue) {
            $win = Resolve-KvmCertWindow -Cfg $cfg -CookieJar $jar -AllowBmcDownload
            $script:CertNotBefore = [datetime]$win.NotBefore
            $script:CertNotAfter = [datetime]$win.NotAfter
            $script:SafeBmcTime = Get-SuggestedBmcTime $script:CertNotBefore $script:CertNotAfter
            $script:CertSource = [string]$win.Source
            Write-Info ("Using suggested: {0:yyyy-MM-dd HH:mm:ss}" -f $script:SafeBmcTime)
        }
        $resp = Set-BmcDateTime $cfg $jar $script:SafeBmcTime
        Write-Info "CGI response: $resp"
        $now = Get-BmcDateTime $cfg $jar
        if ($now) {
            Write-Ok ("BMC now: {0:yyyy-MM-dd HH:mm:ss}" -f $now)
            if ($now -ge $script:CertNotBefore -and $now -le $script:CertNotAfter) { Write-Ok 'Inside cert window' }
            else { Write-Bad 'Still outside window' }
        }
    } catch {
        Write-Bad $_.Exception.Message
    } finally {
        curl.exe -sS -k -m 8 -b $jar -o NUL "$($cfg.Base)/cgi/logout.cgi" | Out-Null
        Remove-Item $jar -Force -ErrorAction SilentlyContinue
    }
}

function Invoke-OpenKvm {
    Write-Title 'Open KVM'
    if (-not (Test-Path $OpenScript)) { Write-Bad "Missing $OpenScript"; return }
    Start-Patcher
    Write-Warn 'If Java Security Warning appears: accept + click Run'
    Write-Warn 'Do not logout IPMI web session while viewer is connecting'
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $OpenScript
}

function Show-Menu {
    Write-Title 'KVM Tool Menu'
    Write-Host '  1) Full diagnose (time/cert/Java/ports/patch)'
    Write-Host ("  2) Set BMC time to suggested ({0:yyyy-MM-dd})" -f $script:SafeBmcTime)
    Write-Host '  3) Start verify=0 auto-patcher (needed on every PC)'
    Write-Host '  4) One-click open KVM'
    Write-Host '  5) New-PC guide / theory'
    Write-Host '  0) Exit'
    Write-Host ''
}

Write-Title 'Supermicro ATEN iKVM Tool'
Write-Info "Folder: $Root"
if ($args -contains '-Diagnose') { Invoke-Diagnose; return }
if ($args -contains '-FixTime') { Invoke-FixBmcTime; return }
if ($args -contains '-Patch') { Start-Patcher; return }
if ($args -contains '-Open') { Invoke-OpenKvm; return }
if ($args -contains '-Help') { Show-Knowledge; return }

while ($true) {
    Show-Menu
    $c = Read-Host 'Select'
    switch ($c) {
        '1' { Invoke-Diagnose }
        '2' { Invoke-FixBmcTime }
        '3' { Start-Patcher }
        '4' { Invoke-OpenKvm }
        '5' { Show-Knowledge }
        '0' { break }
        default { Write-Warn 'Invalid option' }
    }
    if ($c -eq '0') { break }
    Write-Host ''
    Read-Host 'Press Enter to return' | Out-Null
}
