# End-to-end ATEN iKVM debug: patch stunnel, soften TLS, capture certs, report SSL result
$ErrorActionPreference = 'SilentlyContinue'
$OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$ascii = [Text.Encoding]::ASCII
$tempRoot = $env:TEMP
$javaws = 'C:\Program Files (x86)\Java\jre1.8.0_51\bin\javaws.exe'
$jnlp = 'd:\Project\Project\KVM\launch.jnlp'
$capture = 'd:\Project\Project\KVM\capture'
$md = Get-Content 'd:\Project\Project\KVM\kvm.md' -Raw
$pwd = ([regex]::Match($md, 'PASS:\s*(\S+)')).Groups[1].Value
$cookieJar = Join-Path $tempRoot 'ipmi_debug_cookies.txt'
New-Item -ItemType Directory -Force -Path $capture | Out-Null

function Log($m) { Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m) }

function Kill-Related {
    Get-CimInstance Win32_Process | Where-Object {
        $_.Name -like '*stunnel*' -or $_.Name -like 'javaw*' -or $_.Name -like 'javaws*' -or
        $_.CommandLine -like '*patch-stunnel*' -or ($_.CommandLine -like '*debug-kvm*' -and $_.ProcessId -ne $PID)
    } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
}

function Ensure-Bmc {
    Log 'BMC login + time check'
    if (Test-Path $cookieJar) { Remove-Item $cookieJar -Force }
    curl.exe -sS -k -m 20 -c $cookieJar -b $cookieJar --data-urlencode "name=ADMINISTRATOR" --data-urlencode "pwd=$pwd" -o NUL "http://10.12.45.116/cgi/login.cgi" | Out-Null
    $dt = curl.exe -sS -k -m 15 -b $cookieJar --data "GET_DATE_TIME.XML=(0,0)" "http://10.12.45.116/cgi/ipmi.cgi"
    Log ("time: " + ($dt -replace '\s+', ' '))
    if ($dt -notmatch 'YEAR="2015"') {
        $r = curl.exe -sS -k -m 15 -b $cookieJar --data "timezone=0&dst_en=0&ntp=off&ntp_server_pri=&ntp_server_2nd=&year=2015&month=6&day=15&hour=12&min=0&sec=0" "http://10.12.45.116/cgi/config_date_time.cgi"
        Log "set date: $r"
    }
    curl.exe -sS -k -m 20 -b $cookieJar -c $cookieJar -o $jnlp "http://10.12.45.116/cgi/url_redirect.cgi?url_name=ikvm&url_type=jwsk" | Out-Null
}

function Patch-Conf([string]$path) {
    $bytes = [IO.File]::ReadAllBytes($path)
    $offset = 0
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
    $raw = $ascii.GetString($bytes, $offset, $bytes.Length - $offset)

    $raw = [regex]::Replace($raw, '(?m)^\s*verify\s*=\s*\d+\s*$', 'verify = 0')
    $raw = [regex]::Replace($raw, '(?m)^\s*output\s*=\s*.*$', 'output = stunnel_run.log')

    # Soften TLS: comment restrictive options (old WPCM450 often needs TLS1.0)
    foreach ($line in @(
        'options = NO_TLSv1',
        'options = NO_TLSv1.1',
        'sslVersion = TLSv1.2'
    )) {
        $esc = [regex]::Escape($line)
        $raw = [regex]::Replace($raw, "(?m)^\s*$esc\s*$", "; disabled-by-debug: $line")
    }
    if ($raw -notmatch '(?m)^\s*sslVersion\s*=') {
        $raw = $raw -replace '(?m)^(; \* Service definitions.*)$', "sslVersion = all`r`n`r`n`$1"
    }

    if (-not $raw.EndsWith("`n")) { $raw += "`r`n" }
    $tmp = $path + '.tmp'
    [IO.File]::WriteAllBytes($tmp, $ascii.GetBytes($raw))
    [IO.File]::Copy($tmp, $path, $true)
    [IO.File]::Delete($tmp)
    return $raw
}

function Capture-Dir([string]$dir) {
    $dest = Join-Path $capture (Split-Path $dir -Leaf)
    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
    Copy-Item -LiteralPath $dir -Destination $dest -Recurse -Force
    Log "captured -> $dest"
    foreach ($n in @('client.crt', 'server.crt')) {
        $p = Join-Path $dest $n
        if (Test-Path $p) {
            try {
                $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($p)
                Log ("$n Subject=$($cert.Subject)")
                Log ("$n NotBefore=$($cert.NotBefore.ToString('u')) NotAfter=$($cert.NotAfter.ToString('u'))")
                Log ("$n Thumb=$($cert.Thumbprint)")
            } catch { Log "$n parse fail: $($_.Exception.Message)" }
        }
    }
    return $dest
}

function Restart-Stunnel([string]$dir) {
    $exe = Get-ChildItem -LiteralPath $dir -Filter '*stunnel*.exe' | Select-Object -First 1
    if (-not $exe) { return $null }
    Get-CimInstance Win32_Process | Where-Object { $_.ExecutablePath -eq $exe.FullName } | ForEach-Object {
        Log "stop PID $($_.ProcessId)"; Stop-Process -Id $_.ProcessId -Force
    }
    Start-Sleep -Milliseconds 1000
    Get-ChildItem -LiteralPath $dir -Filter 'stunnel*.log' | Remove-Item -Force
    $p = Start-Process -FilePath $exe.FullName -WorkingDirectory $dir -PassThru -WindowStyle Minimized
    Log "start stunnel PID $($p.Id)"
    return $p
}

Kill-Related
Ensure-Bmc

# exception sites
$depDir = Join-Path $env:USERPROFILE 'AppData\LocalLow\Sun\Java\Deployment'
New-Item -ItemType Directory -Force -Path (Join-Path $depDir 'security') | Out-Null
"http://10.12.45.116/`nhttps://10.12.45.116/`n" | Set-Content (Join-Path $depDir 'security\exception.sites') -Encoding ASCII

Log 'launch javaws'
$jp = Start-Process -FilePath $javaws -ArgumentList @('-wait', $jnlp) -PassThru
Log "javaws PID $($jp.Id)"

$deadline = (Get-Date).AddMinutes(2)
$doneDir = $null
$restarted = $false
$result = 'TIMEOUT'

while ((Get-Date) -lt $deadline) {
    foreach ($c in (Get-ChildItem -Path $tempRoot -Recurse -Filter 'stunnel.conf' -ErrorAction SilentlyContinue)) {
        $dir = $c.DirectoryName
        if (-not $restarted) {
            Patch-Conf $c.FullName | Out-Null
            Start-Sleep -Milliseconds 800
            Capture-Dir $dir | Out-Null
            Restart-Stunnel $dir | Out-Null
            $restarted = $true
            $doneDir = $dir
            Log "patched+restarted $dir"
        }
    }

    if ($doneDir) {
        $log = Join-Path $doneDir 'stunnel_run.log'
        if (Test-Path $log) {
            $t = Get-Content -LiteralPath $log -Raw
            if ($t -match 'SSL alert \(read\): fatal: ([^\r\n]+)') {
                $result = "SSL_FAIL: $($Matches[1])"
                Log $result
                break
            }
            if ($t -match 'Cannot open log file') {
                $result = 'LOG_LOCK_FAIL'
                Log $result
                break
            }
            if ($t -match 'connected remote server' -and $t -match 'SSL.*connect.*finished' -and $t -notmatch 'alert \(read\)') {
                # check for successful data transfer later lines
            }
            if ($t -match 'Connection established|bytes sent to SSL' -and $t -match '[1-9][0-9]* byte\(s\) sent to SSL') {
                $result = 'SUCCESS_DATA'
                Log $result
                break
            }
            if ($t -match 'SSL_connect:.*error') {
                $result = 'SSL_CONNECT_ERROR'
                # keep reading a bit for alert line
            }
        }
    }
    Start-Sleep -Milliseconds 300
}

Log "RESULT=$result"
if ($doneDir -and (Test-Path (Join-Path $doneDir 'stunnel_run.log'))) {
    Log '---- stunnel_run.log ----'
    Write-Host (Get-Content (Join-Path $doneDir 'stunnel_run.log') -Raw)
}
if ($doneDir -and (Test-Path (Join-Path $doneDir 'stunnel.conf'))) {
    Log '---- stunnel.conf ----'
    Write-Host (Get-Content (Join-Path $doneDir 'stunnel.conf') -Raw)
}
# copy final logs into capture
if ($doneDir) {
    $leaf = Split-Path $doneDir -Leaf
    $dest = Join-Path $capture $leaf
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    Copy-Item (Join-Path $doneDir '*') $dest -Force -ErrorAction SilentlyContinue
}

Log 'done'
