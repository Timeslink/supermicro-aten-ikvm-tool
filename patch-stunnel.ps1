# Ultra-fast patch only (no stunnel restart). Wins the race before Java starts stunnel.
$ErrorActionPreference = 'SilentlyContinue'
$ascii = [Text.Encoding]::ASCII
$tempRoot = $env:TEMP
Write-Host "[patch] fast patch-only mode on $tempRoot"

function Patch-Text([string]$raw) {
    $raw = [regex]::Replace($raw, '(?m)^\s*verify\s*=\s*\d+\s*$', 'verify = 0')
    $raw = [regex]::Replace($raw, '(?m)^\s*output\s*=\s*.*$', 'output = stunnel_run.log')
    foreach ($line in @('options = NO_TLSv1', 'options = NO_TLSv1.1', 'sslVersion = TLSv1.2')) {
        $raw = [regex]::Replace($raw, "(?m)^\s*$([regex]::Escape($line))\s*$", "; disabled: $line")
    }
    if ($raw -notmatch '(?m)^sslVersion\s*=') { $raw = "sslVersion = all`r`n$raw" }
    if (-not $raw.EndsWith("`n")) { $raw += "`r`n" }
    return $raw
}

function Try-Patch([string]$path) {
    try {
        if (-not (Test-Path -LiteralPath $path)) { return }
        $bytes = [IO.File]::ReadAllBytes($path)
        if ($bytes.Length -lt 20) { return }
        $offset = 0
        if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
        $raw = $ascii.GetString($bytes, $offset, $bytes.Length - $offset)
        if ($raw -match '(?m)^\s*verify\s*=\s*0\s*$' -and $raw -match '(?m)^\s*sslVersion\s*=\s*all\s*$' -and $offset -eq 0) { return }
        $patched = Patch-Text $raw
        $tmp = $path + '.tmp'
        [IO.File]::WriteAllBytes($tmp, $ascii.GetBytes($patched))
        [IO.File]::Copy($tmp, $path, $true)
        [IO.File]::Delete($tmp)
        Write-Host ("[patch] {0}" -f $path)
    } catch {}
}

# FileSystemWatcher for speed
$w = New-Object IO.FileSystemWatcher $tempRoot, 'stunnel.conf'
$w.IncludeSubdirectories = $true
$w.EnableRaisingEvents = $true
$action = { Try-Patch $Event.SourceEventArgs.FullPath }
Register-ObjectEvent $w Created -Action $action | Out-Null
Register-ObjectEvent $w Changed -Action $action | Out-Null

while ($true) {
    foreach ($f in (Get-ChildItem -Path $tempRoot -Recurse -Filter 'stunnel.conf' -ErrorAction SilentlyContinue)) {
        Try-Patch $f.FullName
    }
    Start-Sleep -Milliseconds 50
}
