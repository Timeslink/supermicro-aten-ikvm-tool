# Java 8u51 (32-bit) helpers for ATEN iKVM
$script:JavaInstallerName = 'jre-8u51-windows-i586.exe'
$script:JavaDownloadUrls = @(
    'https://archive.org/download/Java_8_update_51/jre-8u51-windows-i586.exe'
)
$script:JavaExpectedMinBytes = 20MB
$script:JavaTargetVersion = '1.8.0_51'

function Get-PeMachine([string]$exePath) {
    if (-not (Test-Path -LiteralPath $exePath)) { return $null }
    $fs = [IO.File]::OpenRead($exePath)
    try {
        $br = New-Object IO.BinaryReader $fs
        if ($br.ReadUInt16() -ne 0x5A4D) { return $null }
        $fs.Seek(0x3C, 'Begin') | Out-Null
        $pe = $br.ReadInt32()
        $fs.Seek($pe, 'Begin') | Out-Null
        if ($br.ReadUInt32() -ne 0x4550) { return $null }
        return $br.ReadUInt16()
    } catch { return $null } finally { $fs.Dispose() }
}

function Test-PeIsX86([string]$exePath) {
    $m = Get-PeMachine $exePath
    return ($m -eq 0x14c)
}

function Get-JavaVersionFromPath([string]$javawsOrJava) {
    if ($javawsOrJava -match 'jre1\.(\d+)\.0_(\d+)') {
        return ('1.{0}.0_{1}' -f $Matches[1], $Matches[2])
    }
    if ($javawsOrJava -match 'jdk1\.(\d+)\.0_(\d+)') {
        return ('1.{0}.0_{1}' -f $Matches[1], $Matches[2])
    }
    $dir = Split-Path -Parent $javawsOrJava
    $javaExe = Join-Path $dir 'java.exe'
    if (-not (Test-Path $javaExe)) { return $null }
    try {
        $errFile = Join-Path $env:TEMP ('kvm_java_ver_{0}.txt' -f [guid]::NewGuid().ToString('N'))
        $outFile = Join-Path $env:TEMP ('kvm_java_ver_out_{0}.txt' -f [guid]::NewGuid().ToString('N'))
        Start-Process -FilePath $javaExe -ArgumentList @('-version') -NoNewWindow -Wait -PassThru `
            -RedirectStandardError $errFile -RedirectStandardOutput $outFile | Out-Null
        $err = ''
        if (Test-Path $errFile) {
            $err = Get-Content $errFile -Raw -ErrorAction SilentlyContinue
            Remove-Item $errFile, $outFile -Force -ErrorAction SilentlyContinue
        }
        if ($err -match 'version "([^"]+)"') { return $Matches[1] }
    } catch {}
    return $null
}

function Get-JavaInstallInfo {
    $x86Roots = @('C:\Program Files (x86)\Java')
    $x64Roots = @('C:\Program Files\Java')
    $hits32 = @()
    $hits64 = @()

    foreach ($root in $x86Roots) {
        if (-not (Test-Path $root)) { continue }
        Get-ChildItem $root -Recurse -Filter 'javaws.exe' -ErrorAction SilentlyContinue | ForEach-Object {
            $javaExe = Join-Path $_.DirectoryName 'java.exe'
            $is86 = $true
            if (Test-Path $javaExe) { $is86 = Test-PeIsX86 $javaExe }
            $ver = Get-JavaVersionFromPath $_.FullName
            $hits32 += [pscustomobject]@{
                Javaws  = $_.FullName
                JavaExe = $javaExe
                Version = $ver
                Arch    = $(if ($is86) { 'x86' } else { 'x64' })
                Root    = $root
            }
        }
    }
    foreach ($root in $x64Roots) {
        if (-not (Test-Path $root)) { continue }
        $hasJavaws = $false
        Get-ChildItem $root -Recurse -Filter 'javaws.exe' -ErrorAction SilentlyContinue | ForEach-Object {
            $hasJavaws = $true
            $javaExe = Join-Path $_.DirectoryName 'java.exe'
            $ver = Get-JavaVersionFromPath $_.FullName
            $hits64 += [pscustomobject]@{
                Javaws  = $_.FullName
                JavaExe = $javaExe
                Version = $ver
                Arch    = 'x64'
                Root    = $root
            }
        }
        if (-not $hasJavaws) {
            Get-ChildItem $root -Recurse -Filter 'java.exe' -ErrorAction SilentlyContinue |
                Select-Object -First 3 | ForEach-Object {
                    if (-not (Test-PeIsX86 $_.FullName)) {
                        $ver = Get-JavaVersionFromPath $_.FullName
                        $hits64 += [pscustomobject]@{
                            Javaws  = $null
                            JavaExe = $_.FullName
                            Version = $ver
                            Arch    = 'x64'
                            Root    = $root
                        }
                    }
                }
        }
    }

    # Require 8u51; newer Java 8 often rejects these BMC jar signatures.
    $best51 = $hits32 | Where-Object {
        $_.Arch -eq 'x86' -and $_.Javaws -and (
            $_.Version -eq $script:JavaTargetVersion -or $_.Javaws -match 'jre1\.8\.0_51|jdk1\.8\.0_51'
        )
    } | Select-Object -First 1
    $bestOther = $hits32 | Where-Object { $_.Arch -eq 'x86' -and $_.Javaws } | Select-Object -First 1

    $status = 'missing'
    $detail = 'MISSING_32BIT_JAVA8'
    $suggestUninstall = $false
    $best = $null

    if ($best51) {
        $best = $best51
        $status = 'ok'
        $vshow = if ($best.Version) { $best.Version } else { '1.8.0_51' }
        $detail = 'OK_32BIT|' + $vshow + '|' + $best.Javaws
    } elseif ($bestOther) {
        $best = $bestOther
        $status = 'wrong-ver'
        $detail = 'WRONG_VER|' + [string]$best.Version + '|' + $best.Javaws
        $suggestUninstall = $true
    } elseif ($hits64.Count -gt 0) {
        $status = 'wrong-arch'
        $v = ($hits64 | Select-Object -First 1).Version
        $detail = 'WRONG_ARCH_64BIT|' + [string]$v
        $suggestUninstall = $true
    } elseif ((Test-Path 'C:\Program Files (x86)\Java') -or (Test-Path 'C:\Program Files\Java')) {
        $status = 'wrong-ver'
        $detail = 'NO_JAVAWS_JAVA9PLUS'
        $suggestUninstall = $true
    }

    [pscustomobject]@{
        Status           = $status
        Detail           = $detail
        Best             = $best
        Hits32           = $hits32
        Hits64           = $hits64
        SuggestUninstall = $suggestUninstall
        Has64Bit         = ($hits64.Count -gt 0)
    }
}

function Get-JavaStatusMessage($info) {
    switch ($info.Status) {
        'ok' {
            $p = $info.Detail -split '\|', 3
            return ("Already installed 32-bit Java {0}`r`n{1}" -f $p[1], $p[2])
        }
        'wrong-arch' {
            $p = $info.Detail -split '\|', 2
            return ("Only 64-bit Java detected ({0}). This BMC has no 64-bit iKVM native lib.`r`nUninstall 64-bit Java, then install 32-bit Java 8u51." -f $p[1])
        }
        'wrong-ver' {
            if ($info.Detail -eq 'NO_JAVAWS_JAVA9PLUS') {
                return 'Java folder found but javaws missing (likely Java 9+). iKVM needs Java 8 Web Start. Uninstall, then install 32-bit Java 8u51.'
            }
            $p = $info.Detail -split '\|', 3
            return ("32-bit Java found but wrong version: {0}`r`nSuggest uninstall, then install Java 8u51`r`n{1}" -f $p[1], $p[2])
        }
        default {
            return '32-bit Java 8u51 (with javaws) is not installed.'
        }
    }
}

function Get-BundledJavaInstaller([string]$rootDir) {
    $candidates = @(
        (Join-Path $rootDir 'vendor\jre-8u51-windows-i586.exe'),
        (Join-Path $rootDir 'jre-8u51-windows-i586.exe')
    )
    foreach ($p in $candidates) {
        if ((Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p).Length -ge $script:JavaExpectedMinBytes)) {
            return (Resolve-Path -LiteralPath $p).Path
        }
    }
    return $null
}

function Get-JavaInstallerCachePath {
    $dir = Join-Path $env:LOCALAPPDATA 'KVM-Tool\downloads'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Join-Path $dir $script:JavaInstallerName
}

function Copy-JavaInstallerToVendor([string]$sourcePath, [string]$rootDir) {
    $vendor = Join-Path $rootDir 'vendor'
    if (-not (Test-Path $vendor)) { New-Item -ItemType Directory -Path $vendor -Force | Out-Null }
    $dest = Join-Path $vendor $script:JavaInstallerName
    if ($sourcePath -ne $dest) {
        Copy-Item -LiteralPath $sourcePath -Destination $dest -Force
    }
    return $dest
}

function Invoke-JavaInstallerDownloadSync {
    param(
        [Parameter(Mandatory = $true)][string]$Destination,
        [Parameter(Mandatory = $true)][scriptblock]$OnProgress
    )
    $destDir = Split-Path -Parent $Destination
    if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    $tmp = "$Destination.part"
    if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

    $lastErr = $null
    foreach ($url in $script:JavaDownloadUrls) {
        try {
            $req = [Net.HttpWebRequest]::Create($url)
            $req.UserAgent = 'KVM-Tool/1.0'
            $req.AllowAutoRedirect = $true
            $req.Timeout = 60000
            $req.ReadWriteTimeout = 600000
            $resp = $req.GetResponse()
            try {
                $total = $resp.ContentLength
                $stream = $resp.GetResponseStream()
                $fs = [IO.File]::Create($tmp)
                try {
                    $buf = New-Object byte[] 65536
                    $readTotal = [long]0
                    while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                        $fs.Write($buf, 0, $n)
                        $readTotal += $n
                        $pct = 0
                        if ($total -gt 0) { $pct = [int](($readTotal * 100) / $total) }
                        & $OnProgress $pct $readTotal $total
                        try { [System.Windows.Forms.Application]::DoEvents() } catch {}
                    }
                } finally {
                    $fs.Dispose()
                    $stream.Dispose()
                }
            } finally { $resp.Dispose() }

            if (-not (Test-Path $tmp) -or ((Get-Item $tmp).Length -lt $script:JavaExpectedMinBytes)) {
                throw 'Download incomplete'
            }
            if (Test-Path $Destination) { Remove-Item $Destination -Force -ErrorAction SilentlyContinue }
            Move-Item $tmp $Destination -Force
            & $OnProgress 100 ((Get-Item $Destination).Length) ((Get-Item $Destination).Length)
            return $Destination
        } catch {
            $lastErr = $_.Exception.Message
            if (Test-Path $tmp) { Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
        }
    }
    throw ('Download failed: {0}' -f $lastErr)
}

function Start-JavaSilentInstall([string]$installerPath) {
    if (-not (Test-Path -LiteralPath $installerPath)) { throw ('Installer missing: {0}' -f $installerPath) }
    $p = Start-Process -FilePath $installerPath -ArgumentList @('/s') -PassThru -Wait
    return $p.ExitCode
}

function Open-JavaUninstallPanel {
    try {
        Start-Process 'appwiz.cpl'
    } catch {
        Start-Process 'control.exe' -ArgumentList @('appwiz.cpl')
    }
}

function Get-PreferredJavaws32 {
    $info = Get-JavaInstallInfo
    if ($info.Status -eq 'ok' -and $info.Best -and $info.Best.Javaws) {
        return $info.Best.Javaws
    }
    $p51 = 'C:\Program Files (x86)\Java\jre1.8.0_51\bin\javaws.exe'
    if (Test-Path $p51) { return $p51 }
    return $null
}

function Clear-JavaDeploymentCache {
    $roots = @(
        (Join-Path $env:USERPROFILE 'AppData\LocalLow\Sun\Java\Deployment\cache'),
        (Join-Path $env:USERPROFILE 'AppData\LocalLow\Sun\Java\Deployment\tmp'),
        (Join-Path $env:LOCALAPPDATA 'Sun\Java\Deployment\cache')
    )
    $n = 0
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath $r) {
            try {
                Remove-Item -LiteralPath $r -Recurse -Force -ErrorAction Stop
                $n++
            } catch {
                # locked files: try clear children
                Get-ChildItem -LiteralPath $r -Force -ErrorAction SilentlyContinue | ForEach-Object {
                    Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                }
                $n++
            }
        }
    }
    return $n
}

function Add-JavaExceptionSite {
    param([Parameter(Mandatory = $true)][string]$HostAddr)
    $dep = Join-Path $env:USERPROFILE 'AppData\LocalLow\Sun\Java\Deployment\security'
    if (-not (Test-Path $dep)) { New-Item -ItemType Directory -Path $dep -Force | Out-Null }
    $file = Join-Path $dep 'exception.sites'
    $sites = @(
        ('http://{0}' -f $HostAddr),
        ('http://{0}:80' -f $HostAddr),
        ('https://{0}' -f $HostAddr),
        ('https://{0}:443' -f $HostAddr)
    )
    $existing = @()
    if (Test-Path $file) {
        $existing = @(Get-Content -LiteralPath $file -ErrorAction SilentlyContinue | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    }
    $changed = $false
    foreach ($s in $sites) {
        if ($existing -notcontains $s) {
            $existing += $s
            $changed = $true
        }
    }
    if ($changed -or -not (Test-Path $file)) {
        $existing | Set-Content -LiteralPath $file -Encoding ASCII
    }
    return $file
}

function Set-JavaDeploymentRelaxedProps {
    $depDir = Join-Path $env:USERPROFILE 'AppData\LocalLow\Sun\Java\Deployment'
    if (-not (Test-Path $depDir)) { New-Item -ItemType Directory -Path $depDir -Force | Out-Null }
    $props = Join-Path $depDir 'deployment.properties'
    $lines = @()
    if (Test-Path $props) {
        $lines = @(Get-Content -LiteralPath $props -ErrorAction SilentlyContinue)
    }
    $want = @{
        'deployment.security.level'                    = 'MEDIUM'
        'deployment.security.askgrantdialog.show'       = 'true'
        'deployment.security.jsse.hostmismatch.warning' = 'false'
        'deployment.insecure.jres'                      = 'NEVER'
    }
    foreach ($k in $want.Keys) {
        $val = $want[$k]
        $found = $false
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ("^\s*{0}\s*=" -f [regex]::Escape($k))) {
                $lines[$i] = '{0}={1}' -f $k, $val
                $found = $true
                break
            }
        }
        if (-not $found) { $lines += ('{0}={1}' -f $k, $val) }
    }
    $lines | Set-Content -LiteralPath $props -Encoding ASCII
    return $props
}

function Repair-AtenJavaForIkvm {
    param([string]$HostAddr = '')
    $notes = New-Object System.Collections.Generic.List[string]
    $info = Get-JavaInstallInfo
    if ($info.Status -ne 'ok') {
        $notes.Add(('Java check: {0}' -f $info.Status))
        return [pscustomobject]@{ Ok = $false; Info = $info; Notes = $notes }
    }
    $cleared = Clear-JavaDeploymentCache
    $notes.Add(('Cleared Java cache roots: {0}' -f $cleared))
    Set-JavaDeploymentRelaxedProps | Out-Null
    $notes.Add('Relaxed deployment.properties security level')
    if ($HostAddr) {
        $sf = Add-JavaExceptionSite -HostAddr $HostAddr
        $notes.Add(('Exception sites: {0}' -f $sf))
    }
    try { Enable-JavaJarLegacyAlgorithms -JavaHome (Split-Path (Split-Path $info.Best.Javaws -Parent) -Parent) | Out-Null } catch {}
    return [pscustomobject]@{ Ok = $true; Info = $info; Notes = $notes; Javaws = $info.Best.Javaws }
}

function Enable-JavaJarLegacyAlgorithms {
    param([Parameter(Mandatory = $true)][string]$JavaHome)
    $sec = Join-Path $JavaHome 'lib\security\java.security'
    if (-not (Test-Path -LiteralPath $sec)) { return $false }
    $raw = Get-Content -LiteralPath $sec -Raw -Encoding ASCII
    $bak = $sec + '.kvm.bak'
    if (-not (Test-Path $bak)) { Copy-Item -LiteralPath $sec -Destination $bak -Force }
    $new = $raw
    # Keep algorithm list but stop denying old signed JARs (ATEN/SuperMicro)
    $new = [regex]::Replace($new, '(?m)^(jdk\.jar\.disabledAlgorithms=)(.*)$', {
            param($m)
            $v = $m.Groups[2].Value
            $v = $v -replace '\s*,?\s*SHA1\s+denyAfter\s+[0-9-]+', ''
            $v = $v -replace '\s*,?\s*SHA1\s+usage\s+SignedJAR[^\n,]*', ''
            $v = $v -replace '\s*,?\s*MD5(?=\s*,|\s*$)', ''
            $v = $v -replace ',,', ',' -replace '=\s*,', '=' -replace ',\s*$', ''
            return $m.Groups[1].Value + $v.Trim()
        })
    if ($new -ne $raw) {
        Set-Content -LiteralPath $sec -Value $new -Encoding ASCII -NoNewline
        return $true
    }
    return $false
}

function Get-PreferredJavaExe32 {
    $jw = Get-PreferredJavaws32
    if (-not $jw) { return $null }
    $java = Join-Path (Split-Path $jw -Parent) 'java.exe'
    if (Test-Path $java) { return $java }
    return $null
}

function Get-Unpack200Exe {
    $jw = Get-PreferredJavaws32
    if ($jw) {
        $u = Join-Path (Split-Path $jw -Parent) 'unpack200.exe'
        if (Test-Path $u) { return $u }
    }
    return (Find-Unpack200)
}

function ConvertFrom-AtenJnlp([string]$jnlpPath) {
    $xml = [xml](Get-Content -LiteralPath $jnlpPath -Raw -Encoding UTF8)
    $nsm = New-Object System.Xml.XmlNamespaceManager($xml.NameTable)
    # JNLP often has no default xmlns issues; use plain select
    $app = $xml.jnlp.'application-desc'
    if (-not $app) { throw 'JNLP missing application-desc' }
    $main = [string]$app.'main-class'
    $args = @()
    foreach ($a in @($app.argument)) { $args += [string]$a }
    $codebase = [string]$xml.jnlp.codebase
    $jars = @()
    foreach ($res in @($xml.jnlp.resources)) {
        foreach ($j in @($res.jar)) {
            if ($j -and $j.href) {
                $jars += [pscustomobject]@{ Href = [string]$j.href; Main = ([string]$j.main -eq 'true') }
            }
        }
        foreach ($n in @($res.nativelib)) {
            if ($n -and $n.href) {
                # only windows x86 for this tool
                $os = [string]$res.os
                $arch = [string]$res.arch
                if ($os -eq 'Windows' -and ($arch -eq 'x86')) {
                    $jars += [pscustomobject]@{ Href = [string]$n.href; Main = $false; Native = $true }
                }
            }
        }
    }
    [pscustomobject]@{
        MainClass = $main
        Args      = $args
        Codebase  = $codebase.TrimEnd('/')
        Jars      = $jars
    }
}

function Get-AtenJarLocal {
    param(
        [Parameter(Mandatory = $true)][string]$Codebase,
        [Parameter(Mandatory = $true)][string]$Href,
        [Parameter(Mandatory = $true)][string]$DestDir,
        [string]$CookieJar = $null
    )
    if (-not (Test-Path $DestDir)) { New-Item -ItemType Directory -Path $DestDir -Force | Out-Null }
    $name = [IO.Path]::GetFileName($Href)
    $outJar = Join-Path $DestDir $name
    $packUrl = $Codebase.TrimEnd('/') + '/' + $Href + '.pack.gz'
    $jarUrl = $Codebase.TrimEnd('/') + '/' + $Href
    $packFile = Join-Path $DestDir ($name + '.pack.gz')
    $curlArgs = @('-sS', '-k', '-m', '120', '-L')
    if ($CookieJar) { $curlArgs += @('-b', $CookieJar) }

    & curl.exe @curlArgs -o $packFile $packUrl | Out-Null
    $unpack200 = Get-Unpack200Exe
    if ((Test-Path $packFile) -and ((Get-Item $packFile).Length -gt 1000) -and $unpack200) {
        if (Test-Path $outJar) { Remove-Item $outJar -Force }
        & $unpack200 $packFile $outJar 2>$null | Out-Null
        if ((Test-Path $outJar) -and ((Get-Item $outJar).Length -gt 1000)) { return $outJar }
    }

    & curl.exe @curlArgs -o $outJar $jarUrl | Out-Null
    if ((Test-Path $outJar) -and ((Get-Item $outJar).Length -gt 1000)) {
        # reject HTML error pages
        $head = Get-Content $outJar -TotalCount 1 -ErrorAction SilentlyContinue
        if ($head -match '^\s*<') { throw ("Not a JAR (HTML): {0}" -f $jarUrl) }
        return $outJar
    }
    throw ("Failed to download {0}" -f $Href)
}

function Expand-AtenNativeLibs([string]$nativeJar, [string]$nativeDir) {
    if (-not (Test-Path $nativeDir)) { New-Item -ItemType Directory -Path $nativeDir -Force | Out-Null }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($nativeJar)
    try {
        foreach ($e in $zip.Entries) {
            if ($e.FullName -match '\.(dll|so|dylib)$') {
                $dest = Join-Path $nativeDir ([IO.Path]::GetFileName($e.FullName))
                $fs = [IO.File]::Open($dest, 'Create')
                try {
                    $es = $e.Open()
                    try { $es.CopyTo($fs) } finally { $es.Dispose() }
                } finally { $fs.Dispose() }
            }
        }
    } finally { $zip.Dispose() }
    return $nativeDir
}

function Start-AtenIkvmDirect {
    param(
        [Parameter(Mandatory = $true)][string]$JnlpPath,
        [Parameter(Mandatory = $true)][string]$WorkDir,
        [string]$CookieJar = $null
    )
    $java = Get-PreferredJavaExe32
    if (-not $java) { throw '32-bit java.exe (8u51) not found' }
    $meta = ConvertFrom-AtenJnlp $JnlpPath
    $libDir = Join-Path $WorkDir 'ikvm_libs'
    $nativeDir = Join-Path $WorkDir 'ikvm_native'
    if (Test-Path $libDir) { Remove-Item $libDir -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -ItemType Directory -Path $libDir -Force | Out-Null

    $cp = New-Object System.Collections.Generic.List[string]
    foreach ($j in $meta.Jars) {
        $local = Get-AtenJarLocal -Codebase $meta.Codebase -Href $j.Href -DestDir $libDir -CookieJar $CookieJar
        [void]$cp.Add($local)
        if ($j.Native) { Expand-AtenNativeLibs $local $nativeDir | Out-Null }
    }
    if (-not (Test-Path $nativeDir)) {
        # fallback: any jar named libwin_x86
        $n = Get-ChildItem $libDir -Filter 'libwin_x86*.jar' | Select-Object -First 1
        if ($n) { Expand-AtenNativeLibs $n.FullName $nativeDir | Out-Null }
    }

    $cpStr = [string]::Join(';', $cp)
    $vmArgs = @('-Xmx128M', '-Xms128M', '-Xss1M', ('-Djava.library.path={0}' -f $nativeDir), '-cp', $cpStr, $meta.MainClass) + $meta.Args
    Write-Host ("direct launch: {0}" -f $meta.MainClass)
    Write-Host ("classpath jars: {0}" -f $cp.Count)
    return (Start-Process -FilePath $java -ArgumentList $vmArgs -WorkingDirectory $WorkDir -PassThru)
}
