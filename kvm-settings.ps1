# Shared encrypted settings for KVM Tool (Windows DPAPI, CurrentUser)
Add-Type -AssemblyName System.Security | Out-Null

$script:KvmSettingsDir = Join-Path $env:LOCALAPPDATA 'KVM-Tool'
$script:KvmSettingsPath = Join-Path $script:KvmSettingsDir 'settings.json'
$script:KvmEntropy = [Text.Encoding]::UTF8.GetBytes('Supermicro-ATEN-iKVM-Tool-v1')
$script:KvmCacheDir = Join-Path $script:KvmSettingsDir 'cache'

function Protect-KvmSecret([string]$plain) {
    if ([string]::IsNullOrEmpty($plain)) { return '' }
    $bytes = [Text.Encoding]::UTF8.GetBytes($plain)
    $prot = [Security.Cryptography.ProtectedData]::Protect(
        $bytes, $script:KvmEntropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($prot)
}

function Unprotect-KvmSecret([string]$b64) {
    if ([string]::IsNullOrWhiteSpace($b64)) { return '' }
    $prot = [Convert]::FromBase64String($b64)
    $bytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $prot, $script:KvmEntropy,
        [Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Text.Encoding]::UTF8.GetString($bytes)
}

function Get-KvmSettingsPath { $script:KvmSettingsPath }
function Test-KvmSettingsExists { Test-Path -LiteralPath $script:KvmSettingsPath }

function New-KvmSettingsObject {
    [pscustomobject]@{
        Host     = '10.12.45.116'
        User     = 'ADMINISTRATOR'
        Password = ''
        UseHttps = $false
    }
}

function Read-KvmPlainMd([string]$mdPath) {
    if (-not (Test-Path -LiteralPath $mdPath)) { return $null }
    $raw = Get-Content -LiteralPath $mdPath -Raw -Encoding UTF8
    $o = New-KvmSettingsObject
    if ($raw -match 'USER:\s*(\S+)') { $o.User = $Matches[1] }
    if ($raw -match 'PASS:\s*(\S+)') { $o.Password = $Matches[1] }
    if ($raw -match 'https?://([0-9.]+)') { $o.Host = $Matches[1] }
    if ($raw -match 'https://') { $o.UseHttps = $true }
    return $o
}

function Get-KvmBaseUrl([string]$hostAddr, [bool]$useHttps) {
    $scheme = 'http'
    if ($useHttps) { $scheme = 'https' }
    return ($scheme + '://' + $hostAddr)
}

function Get-SuggestedBmcTime([datetime]$notBefore, [datetime]$notAfter) {
    if ($notAfter -le $notBefore) { throw 'Invalid cert window' }
    # About 6 months before cert end, clamped inside the window.
    $suggest = $notAfter.AddMonths(-6)
    $min = $notBefore.AddDays(1)
    $max = $notAfter.AddDays(-1)
    if ($suggest -lt $min) { $suggest = $min }
    if ($suggest -gt $max) { $suggest = $max }
    # Noon UTC-ish local noon for readability
    return (Get-Date -Year $suggest.Year -Month $suggest.Month -Day $suggest.Day -Hour 12 -Minute 0 -Second 0)
}

function Get-X509Dates([string]$certPath) {
    if (-not (Test-Path -LiteralPath $certPath)) { return $null }
    try {
        $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2((Resolve-Path $certPath).Path)
        return [pscustomobject]@{
            Path      = $certPath
            Subject   = $cert.Subject
            NotBefore = $cert.NotBefore
            NotAfter  = $cert.NotAfter
        }
    } catch { return $null }
}

function Find-TempKvmCertWindow {
    $files = @(Get-ChildItem -Path $env:TEMP -Recurse -Filter 'client.crt' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 8)
    foreach ($f in $files) {
        $dir = $f.DirectoryName
        if (-not (Test-Path (Join-Path $dir 'stunnel.conf'))) { continue }
        $c = Get-X509Dates $f.FullName
        $s = Get-X509Dates (Join-Path $dir 'server.crt')
        if (-not $c) { continue }
        $nb = $c.NotBefore
        $na = $c.NotAfter
        if ($s) {
            if ($s.NotBefore -gt $nb) { $nb = $s.NotBefore }
            if ($s.NotAfter -lt $na) { $na = $s.NotAfter }
        }
        return [pscustomobject]@{
            NotBefore = $nb
            NotAfter  = $na
            Source    = 'temp-stunnel'
            Detail    = $dir
        }
    }
    return $null
}

function Find-Unpack200 {
    $hit = Get-ChildItem 'C:\Program Files (x86)\Java' -Recurse -Filter 'unpack200.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if ($hit) { return $hit }
    return (Get-ChildItem 'C:\Program Files\Java' -Recurse -Filter 'unpack200.exe' -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName)
}

function Find-KvmCertWindowFromBmc {
    param(
        [Parameter(Mandatory = $true)]$Cfg,
        [Parameter(Mandatory = $true)][string]$CookieJar
    )
    # Download iKVM pack200 jar and unpack with Java 8 unpack200, then scan for certs
    if (-not (Test-Path $script:KvmCacheDir)) {
        New-Item -ItemType Directory -Path $script:KvmCacheDir -Force | Out-Null
    }
    $unpack200 = Find-Unpack200
    if (-not $unpack200) { return $null }

    $pack = Join-Path $script:KvmCacheDir 'iKVM.jar.pack.gz'
    $jar = Join-Path $script:KvmCacheDir 'iKVM.jar'
    $url = $Cfg.Base.TrimEnd('/') + '/iKVM__V1.69.39.0x0.jar.pack.gz'
    # Also try reading name from a fresh jnlp if possible
    $jnlpTmp = Join-Path $script:KvmCacheDir 'probe.jnlp'
    curl.exe -sS -k -m 30 -b $CookieJar -o $jnlpTmp ($Cfg.Base.TrimEnd('/') + '/cgi/url_redirect.cgi?url_name=ikvm&url_type=jwsk') | Out-Null
    if (Test-Path $jnlpTmp) {
        $jtxt = Get-Content $jnlpTmp -Raw -ErrorAction SilentlyContinue
        if ($jtxt -match 'href="([^"]*iKVM[^"]+\.jar)"') {
            $url = $Cfg.Base.TrimEnd('/') + '/' + $Matches[1] + '.pack.gz'
            # jar href is like iKVM__V1.69.39.0x0.jar -> pack.gz appended after .jar is wrong
            # correct: iKVM__V1.69.39.0x0.jar.pack.gz
            $href = $Matches[1]
            $url = $Cfg.Base.TrimEnd('/') + '/' + $href + '.pack.gz'
        }
    }

    curl.exe -sS -k -m 120 -b $CookieJar -o $pack $url | Out-Null
    if (-not (Test-Path $pack) -or ((Get-Item $pack).Length -lt 1000)) {
        # fallback known name
        $url = $Cfg.Base.TrimEnd('/') + '/iKVM__V1.69.39.0x0.jar.pack.gz'
        curl.exe -sS -k -m 120 -b $CookieJar -o $pack $url | Out-Null
    }
    if (-not (Test-Path $pack) -or ((Get-Item $pack).Length -lt 1000)) { return $null }

    if (Test-Path $jar) { Remove-Item $jar -Force -ErrorAction SilentlyContinue }
    & $unpack200 $pack $jar 2>$null | Out-Null
    if (-not (Test-Path $jar)) { return $null }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($jar)
    try {
        $extractDir = Join-Path $script:KvmCacheDir 'jar_extract'
        if (Test-Path $extractDir) { Remove-Item $extractDir -Recurse -Force -ErrorAction SilentlyContinue }
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        $found = @()
        foreach ($e in $zip.Entries) {
            $name = $e.FullName
            if ($name -match '\.(crt|cer|pem)$' -or $name -match '(?i)(client|server|ssl|cert)') {
                if ($e.Length -lt 200 -or $e.Length -gt 20000) { continue }
                $out = Join-Path $extractDir ([IO.Path]::GetFileName($name))
                if ([string]::IsNullOrWhiteSpace([IO.Path]::GetFileName($name))) { continue }
                $fs = [IO.File]::Open($out, 'Create')
                try {
                    $es = $e.Open()
                    try { $es.CopyTo($fs) } finally { $es.Dispose() }
                } finally { $fs.Dispose() }
                $d = Get-X509Dates $out
                if ($d) { $found += $d }
            }
        }
    } finally { $zip.Dispose() }

    if ($found.Count -eq 0) { return $null }
    $nb = ($found | Measure-Object -Property NotBefore -Maximum).Maximum
    # intersection-ish: latest NotBefore, earliest NotAfter
    $nb = ($found | Sort-Object NotBefore -Descending | Select-Object -First 1).NotBefore
    $na = ($found | Sort-Object NotAfter | Select-Object -First 1).NotAfter
    return [pscustomobject]@{
        NotBefore = $nb
        NotAfter  = $na
        Source    = 'bmc-ikvm-jar'
        Detail    = $url
    }
}

function Resolve-KvmCertWindow {
    param(
        $Cfg = $null,
        [string]$CookieJar = $null,
        [switch]$AllowBmcDownload
    )
    $win = Find-TempKvmCertWindow
    if ($win) { return $win }

    if ($AllowBmcDownload -and $Cfg -and $CookieJar) {
        $win = Find-KvmCertWindowFromBmc -Cfg $Cfg -CookieJar $CookieJar
        if ($win) { return $win }
    }

    # fallback to previously saved window
    if (Test-KvmSettingsExists) {
        try {
            $json = Get-Content -LiteralPath $script:KvmSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($json.CertNotBefore -and $json.CertNotAfter) {
                return [pscustomobject]@{
                    NotBefore = [datetime]$json.CertNotBefore
                    NotAfter  = [datetime]$json.CertNotAfter
                    Source    = 'saved-settings'
                    Detail    = $script:KvmSettingsPath
                }
            }
        } catch {}
    }

    # last-known default for this SuperMicro ATEN profile (observed)
    return [pscustomobject]@{
        NotBefore = [datetime]'2016-05-19'
        NotAfter  = [datetime]'2026-05-17'
        Source    = 'builtin-default'
        Detail    = 'ATEN iKVM observed defaults'
    }
}

function Load-KvmSettings {
    if (-not (Test-KvmSettingsExists)) { return $null }
    $json = Get-Content -LiteralPath $script:KvmSettingsPath -Raw -Encoding UTF8
    $obj = $json | ConvertFrom-Json
    $pass = ''
    try {
        $pass = Unprotect-KvmSecret ([string]$obj.PasswordDpapi)
    } catch {
        throw 'Settings decrypt failed (different Windows user/PC). Re-enter password and save.'
    }
    $hostAddr = [string]$obj.Host
    $useHttps = [bool]$obj.UseHttps
    $nb = $null; $na = $null; $sug = $null
    if ($obj.CertNotBefore) { $nb = [datetime]$obj.CertNotBefore }
    if ($obj.CertNotAfter) { $na = [datetime]$obj.CertNotAfter }
    if ($obj.SuggestedBmcTime) { $sug = [datetime]$obj.SuggestedBmcTime }
    [pscustomobject]@{
        Host             = $hostAddr
        User             = [string]$obj.User
        Password         = $pass
        UseHttps         = $useHttps
        Base             = (Get-KvmBaseUrl $hostAddr $useHttps)
        Path             = $script:KvmSettingsPath
        CertNotBefore    = $nb
        CertNotAfter     = $na
        SuggestedBmcTime = $sug
        CertSource       = [string]$obj.CertSource
    }
}

function Save-KvmSettings {
    param(
        [Parameter(Mandatory = $true)][Alias('Host')][string]$BmcHost,
        [Parameter(Mandatory = $true)][string]$User,
        [Parameter(Mandatory = $true)][string]$Password,
        [bool]$UseHttps = $false,
        [datetime]$CertNotBefore = [datetime]::MinValue,
        [datetime]$CertNotAfter = [datetime]::MinValue,
        [datetime]$SuggestedBmcTime = [datetime]::MinValue,
        [string]$CertSource = ''
    )
    if ([string]::IsNullOrWhiteSpace($BmcHost)) { throw 'Host is empty' }
    if ([string]::IsNullOrWhiteSpace($User)) { throw 'User is empty' }
    if ($null -eq $Password) { $Password = '' }

    if (-not (Test-Path -LiteralPath $script:KvmSettingsDir)) {
        New-Item -ItemType Directory -Path $script:KvmSettingsDir -Force | Out-Null
    }

    # preserve existing cert window if not provided
    $old = $null
    if (Test-KvmSettingsExists) {
        try { $old = Get-Content $script:KvmSettingsPath -Raw | ConvertFrom-Json } catch {}
    }

    $payload = [ordered]@{
        Host          = $BmcHost.Trim()
        User          = $User.Trim()
        PasswordDpapi = (Protect-KvmSecret $Password)
        UseHttps      = [bool]$UseHttps
        UpdatedAt     = (Get-Date).ToString('o')
        ProtectScope  = 'CurrentUser'
        Note          = 'Password encrypted with Windows DPAPI CurrentUser scope.'
    }

    if ($CertNotBefore -ne [datetime]::MinValue -and $CertNotAfter -ne [datetime]::MinValue) {
        $payload.CertNotBefore = $CertNotBefore.ToString('o')
        $payload.CertNotAfter = $CertNotAfter.ToString('o')
        if ($SuggestedBmcTime -eq [datetime]::MinValue) {
            $SuggestedBmcTime = Get-SuggestedBmcTime $CertNotBefore $CertNotAfter
        }
        $payload.SuggestedBmcTime = $SuggestedBmcTime.ToString('o')
        $payload.CertSource = $CertSource
    } elseif ($old) {
        if ($old.CertNotBefore) { $payload.CertNotBefore = $old.CertNotBefore }
        if ($old.CertNotAfter) { $payload.CertNotAfter = $old.CertNotAfter }
        if ($old.SuggestedBmcTime) { $payload.SuggestedBmcTime = $old.SuggestedBmcTime }
        if ($old.CertSource) { $payload.CertSource = $old.CertSource }
    }

    ($payload | ConvertTo-Json) | Set-Content -LiteralPath $script:KvmSettingsPath -Encoding UTF8
    return $script:KvmSettingsPath
}

function Get-KvmConfigOrThrow {
    param([string]$LegacyMdPath)
    if (Test-KvmSettingsExists) {
        return (Load-KvmSettings)
    }
    if ($LegacyMdPath -and (Test-Path -LiteralPath $LegacyMdPath)) {
        $legacy = Read-KvmPlainMd $LegacyMdPath
        if ($legacy -and $legacy.Password) {
            return [pscustomobject]@{
                Host     = $legacy.Host
                User     = $legacy.User
                Password = $legacy.Password
                UseHttps = $legacy.UseHttps
                Base     = (Get-KvmBaseUrl $legacy.Host $legacy.UseHttps)
                Path     = $LegacyMdPath
                IsLegacy = $true
            }
        }
    }
    throw 'No encrypted settings yet. Open KVM-Tool-UI, fill IP/user/password, click Save.'
}

function Clear-KvmLegacyPlaintext([string]$mdPath) {
    if (-not (Test-Path -LiteralPath $mdPath)) { return $false }
    $text = @(
        '# Credentials moved to encrypted Windows DPAPI store:'
        '# %LOCALAPPDATA%\KVM-Tool\settings.json'
        '# Plaintext password removed from this file.'
    ) -join "`r`n"
    Set-Content -LiteralPath $mdPath -Value $text -Encoding UTF8
    return $true
}
