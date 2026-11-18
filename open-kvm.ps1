# One-click open Supermicro ATEN iKVM (reads DPAPI settings)
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
if ($MyInvocation.MyCommand.CommandType -eq 'ExternalScript') {
    $Root = Split-Path -Parent -Path $MyInvocation.MyCommand.Definition
} else {
    $Root = Split-Path -Parent -Path ([Environment]::GetCommandLineArgs()[0])
    if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Get-Location).Path }
}

. (Join-Path $Root 'kvm-settings.ps1')
. (Join-Path $Root 'kvm-java.ps1')

$jnlp = Join-Path $Root 'launch.jnlp'
$patch = Join-Path $Root 'patch-stunnel.ps1'
$legacyMd = Join-Path $Root 'kvm.md'

$javaws = Get-PreferredJavaws32
if (-not $javaws) {
    $jinfo = Get-JavaInstallInfo
    Write-Host '[XX] Need 32-bit Java 8u51 (exact). Newer Java 8 causes JARSigningException on ATEN jars.'
    Write-Host ("[XX] Current: {0}" -f $jinfo.Detail)
    Write-Host 'Install via KVM-Tool-UI -> 检查/安装Java (bundled jre-8u51-windows-i586).'
    exit 2
}
Write-Host "javaws=$javaws"

try {
    $cfg = Get-KvmConfigOrThrow -LegacyMdPath $legacyMd
} catch {
    Write-Host $_.Exception.Message
    Write-Host '请先运行 KVM-Tool-UI.exe 填写并「保存设置」。'
    exit 1
}
if ($cfg.PSObject.Properties.Name -contains 'IsLegacy' -and $cfg.IsLegacy) {
    Write-Host '[!!] 正在使用旧版 kvm.md 明文。请尽快在 UI 中保存加密设置。'
}

$user = $cfg.User
$pwd = $cfg.Password
$base = $cfg.Base
$hostAddr = $cfg.Host

Write-Host "BMC=$hostAddr user=$user"
Write-Host 'cleanup old java/stunnel...'
Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.Name -like '*stunnel*' -or $_.Name -like 'javaw*' -or $_.Name -like 'javaws*'
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Start-Sleep 1

$patchRunning = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*patch-stunnel.ps1*' }
if (-not $patchRunning) {
    Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $patch) -WindowStyle Minimized
    Write-Host 'patcher started'
    Start-Sleep 1
} else {
    Write-Host 'patcher already running'
}

$jar = Join-Path $env:TEMP 'ipmi_open_kvm.txt'
curl.exe -sS -k -m 20 -c $jar -b $jar --data-urlencode "name=$user" --data-urlencode "pwd=$pwd" -o NUL "$base/cgi/login.cgi" | Out-Null

Write-Host 'resolve KVM cert allow-window + suggested BMC time...'
$win = Resolve-KvmCertWindow -Cfg $cfg -CookieJar $jar -AllowBmcDownload
$suggest = Get-SuggestedBmcTime $win.NotBefore $win.NotAfter
Write-Host ("cert window [{0}]: {1:yyyy-MM-dd} ~ {2:yyyy-MM-dd}" -f $win.Source, $win.NotBefore, $win.NotAfter)
Write-Host ("set BMC time -> {0:yyyy-MM-dd HH:mm:ss}" -f $suggest)
$timeBody = ("timezone=0&dst_en=0&ntp=off&ntp_server_pri=&ntp_server_2nd=&year={0}&month={1}&day={2}&hour={3}&min={4}&sec={5}" -f `
    $suggest.Year, $suggest.Month, $suggest.Day, $suggest.Hour, $suggest.Minute, $suggest.Second)
curl.exe -sS -k -m 15 -b $jar --data $timeBody -o NUL "$base/cgi/config_date_time.cgi" | Out-Null

# persist discovered window for UI / next launch
try {
    Save-KvmSettings -Host $hostAddr -User $user -Password $pwd -UseHttps:$cfg.UseHttps `
        -CertNotBefore $win.NotBefore -CertNotAfter $win.NotAfter `
        -SuggestedBmcTime $suggest -CertSource $win.Source | Out-Null
} catch {}

curl.exe -sS -k -m 20 -b $jar -c $jar -o $jnlp "$base/cgi/url_redirect.cgi?url_name=ikvm&url_type=jwsk" | Out-Null
Write-Host ("jnlp ready ({0} bytes), session kept" -f (Get-Item $jnlp).Length)

Write-Host 'prepare Java env (optional cache cleanup)...'
try {
    $fix = Repair-AtenJavaForIkvm -HostAddr $hostAddr
    foreach ($n in $fix.Notes) { Write-Host ("  {0}" -f $n) }
} catch {}

$startedAt = Get-Date
# Prefer direct java launch; Web Start signature checks often fail on these BMC jars.
Write-Host 'launching iKVM via java -cp...'
$work = Join-Path $env:TEMP ('kvm_ikvm_' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work -Force | Out-Null
try {
    $proc = Start-AtenIkvmDirect -JnlpPath $jnlp -WorkDir $work -CookieJar $jar
    Write-Host ("java PID {0}" -f $proc.Id)
} catch {
    Write-Host ("[XX] direct launch failed: {0}" -f $_.Exception.Message)
    Write-Host 'fallback: javaws (may hit JARSigningException)...'
    Start-Process -FilePath $javaws -ArgumentList @($jnlp)
}

Add-Type -TypeDefinition @'
using System; using System.Text; using System.Runtime.InteropServices;
public class OpenKvmClick {
  public delegate bool Cb(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(Cb cb, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  public struct RECT { public int L,T,R,B; }
}
'@

Write-Host 'if Security Warning appears, auto-click Run...'
for ($i = 0; $i -lt 45; $i++) {
    $sec = [IntPtr]::Zero
    [OpenKvmClick]::EnumWindows({
            param($h, $l)
            if (-not [OpenKvmClick]::IsWindowVisible($h)) { return $true }
            $sb = New-Object Text.StringBuilder 256
            [void][OpenKvmClick]::GetWindowText($h, $sb, 256)
            if ($sb.ToString() -eq '安全警告') { $script:sec = $h }
            return $true
        }, [IntPtr]::Zero) | Out-Null
    if ($script:sec -ne [IntPtr]::Zero) {
        $r = New-Object OpenKvmClick+RECT
        [void][OpenKvmClick]::GetWindowRect($script:sec, [ref]$r)
        [void][OpenKvmClick]::SetForegroundWindow($script:sec)
        $chkX = [int]($r.L + ($r.R - $r.L) * 0.12); $chkY = [int]($r.T + ($r.B - $r.T) * 0.72)
        $runX = [int]($r.L + ($r.R - $r.L) * 0.75); $runY = [int]($r.T + ($r.B - $r.T) * 0.88)
        [void][OpenKvmClick]::SetCursorPos($chkX, $chkY); [OpenKvmClick]::mouse_event(0x2, 0, 0, 0, [UIntPtr]::Zero); [OpenKvmClick]::mouse_event(0x4, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 250
        [void][OpenKvmClick]::SetCursorPos($runX, $runY); [OpenKvmClick]::mouse_event(0x2, 0, 0, 0, [UIntPtr]::Zero); [OpenKvmClick]::mouse_event(0x4, 0, 0, 0, [UIntPtr]::Zero)
        Write-Host 'clicked Run'
        break
    }
    Start-Sleep 1
}

Write-Host 'waiting SSL...'
$ok = $false
for ($i = 0; $i -lt 90; $i++) {
    Start-Sleep 1
    $sec2 = [IntPtr]::Zero
    [OpenKvmClick]::EnumWindows({
            param($h, $l)
            if (-not [OpenKvmClick]::IsWindowVisible($h)) { return $true }
            $sb = New-Object Text.StringBuilder 256
            [void][OpenKvmClick]::GetWindowText($h, $sb, 256)
            if ($sb.ToString() -eq '安全警告') { $script:sec2 = $h }
            return $true
        }, [IntPtr]::Zero) | Out-Null
    if ($script:sec2 -ne [IntPtr]::Zero) {
        $r = New-Object OpenKvmClick+RECT
        [void][OpenKvmClick]::GetWindowRect($script:sec2, [ref]$r)
        [void][OpenKvmClick]::SetForegroundWindow($script:sec2)
        $chkX = [int]($r.L + ($r.R - $r.L) * 0.12); $chkY = [int]($r.T + ($r.B - $r.T) * 0.72)
        $runX = [int]($r.L + ($r.R - $r.L) * 0.75); $runY = [int]($r.T + ($r.B - $r.T) * 0.88)
        [void][OpenKvmClick]::SetCursorPos($chkX, $chkY); [OpenKvmClick]::mouse_event(0x2, 0, 0, 0, [UIntPtr]::Zero); [OpenKvmClick]::mouse_event(0x4, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 200
        [void][OpenKvmClick]::SetCursorPos($runX, $runY); [OpenKvmClick]::mouse_event(0x2, 0, 0, 0, [UIntPtr]::Zero); [OpenKvmClick]::mouse_event(0x4, 0, 0, 0, [UIntPtr]::Zero)
    }

    $logs = Get-ChildItem $env:TEMP -Recurse -Filter 'stunnel_run.log' -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -gt $startedAt } |
        Sort-Object LastWriteTime -Descending
    foreach ($l in $logs) {
        $t = Get-Content $l.FullName -Raw -ErrorAction SilentlyContinue
        if ($t -match 'SSL connected: new session negotiated') {
            if ($t -match 'close notify' -and $t -notmatch '[1-9]\d{2,} byte\(s\) sent to SSL') {
                Write-Host 'SSL up then closed quickly - still watching...'
            } else {
                Write-Host 'SSL OK - check Java iKVM Viewer window'
                $ok = $true
                break
            }
        }
        if ($t -match 'alert \(read\): fatal: ([^\r\n]+)') {
            Write-Host ("SSL FAIL: {0}" -f $Matches[1])
        }
    }
    if ($ok) { break }
}
if (-not $ok) { Write-Host 'SSL not confirmed. Click Run on Security Warning if still open.' }
