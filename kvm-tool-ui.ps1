#Requires -Version 5.1
# Supermicro ATEN iKVM - WinForms UI (DPAPI encrypted settings)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Security
[System.Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = 'Continue'

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
$JavaLib = Join-Path $Root 'kvm-java.ps1'
. $SettingsLib
. $JavaLib

# Runtime cert window (auto-detected on diagnose; falls back to saved/default)
$script:CertNotBefore = [datetime]'2016-05-19'
$script:CertNotAfter  = [datetime]'2026-05-17'
$script:SafeBmcTime   = Get-SuggestedBmcTime $script:CertNotBefore $script:CertNotAfter
$script:CertSource    = 'builtin-default'

function New-CookieJar {
    Join-Path $env:TEMP ("kvm_ui_{0}.txt" -f [guid]::NewGuid().ToString('N'))
}

function Get-UiConfig {
    $hostAddr = $txtHost.Text.Trim()
    $user = $txtUser.Text.Trim()
    $pass = $txtPass.Text
    if ([string]::IsNullOrWhiteSpace($hostAddr)) { throw '请填写 BMC IP/主机' }
    if ([string]::IsNullOrWhiteSpace($user)) { throw '请填写用户名' }
    if ([string]::IsNullOrEmpty($pass)) { throw '请填写密码' }
    $https = $chkHttps.Checked
    $scheme = 'http'
    if ($https) { $scheme = 'https' }
    [pscustomobject]@{
        Host = $hostAddr; User = $user; Pass = $pass; Password = $pass
        UseHttps = $https; Base = ($scheme + '://' + $hostAddr)
    }
}

function Invoke-BmcLogin($cfg, $jar) {
    $code = curl.exe -sS -k -m 20 -c $jar -b $jar -o NUL -w "%{http_code}" `
        --data-urlencode "name=$($cfg.User)" --data-urlencode "pwd=$($cfg.Pass)" `
        "$($cfg.Base)/cgi/login.cgi"
    if ($code -ne '200') { throw "登录失败 HTTP $code" }
    if (-not (Select-String -Path $jar -Pattern '\tSID\t\S+' -Quiet)) { throw '登录失败：无 SID' }
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
    Get-Date -Year ([int]$y) -Month ([int]$mo) -Day ([int]$d) -Hour ([int]$h) -Minute ([int]$mi) -Second ([int]$s)
}

function Set-BmcDateTime($cfg, $jar, [datetime]$when) {
    $body = "timezone=0&dst_en=0&ntp=off&ntp_server_pri=&ntp_server_2nd=" +
        "&year=$($when.Year)&month=$($when.Month)&day=$($when.Day)" +
        "&hour=$($when.Hour)&min=$($when.Minute)&sec=$($when.Second)"
    curl.exe -sS -k -m 20 -b $jar --data $body "$($cfg.Base)/cgi/config_date_time.cgi"
}

function Get-PowerStatus($cfg, $jar) {
    $xml = curl.exe -sS -k -m 15 -b $jar --data 'POWER_INFO.XML=(0,0)' "$($cfg.Base)/cgi/ipmi.cgi"
    [regex]::Match($xml, 'STATUS="([^"]+)"').Groups[1].Value
}

function Test-PortOpen($hostAddr, $port, $timeoutMs = 1500) {
    $tcp = New-Object System.Net.Sockets.TcpClient
    try {
        $iar = $tcp.BeginConnect($hostAddr, $port, $null, $null)
        if (-not $iar.AsyncWaitHandle.WaitOne($timeoutMs, $false)) { return $false }
        return $tcp.Connected
    } catch { return $false } finally { $tcp.Close() }
}

function Test-PatcherRunning {
    [bool](Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like '*patch-stunnel.ps1*' })
}

function Add-Log([string]$msg) {
    $ts = Get-Date -Format 'HH:mm:ss'
    $line = "[$ts] $msg"
    $box = $script:txtLog
    if ($box.InvokeRequired) {
        $box.Invoke([Action] {
                $box.AppendText("$line`r`n")
                $box.SelectionStart = $box.TextLength
                $box.ScrollToCaret()
            })
    } else {
        $box.AppendText("$line`r`n")
        $box.SelectionStart = $box.TextLength
        $box.ScrollToCaret()
    }
}

function Set-StatusLabel([System.Windows.Forms.Label]$lbl, [string]$text, [string]$state) {
    $lbl.Text = $text
    switch ($state) {
        'ok'   { $lbl.ForeColor = [Drawing.Color]::ForestGreen }
        'bad'  { $lbl.ForeColor = [Drawing.Color]::Firebrick }
        'warn' { $lbl.ForeColor = [Drawing.Color]::DarkOrange }
        default { $lbl.ForeColor = [Drawing.Color]::DimGray }
    }
}

function Set-Busy([bool]$busy) {
    foreach ($b in @($btnSave, $btnDiag, $btnTime, $btnPatch, $btnOpen, $btnJava, $btnHelp, $btnClear)) {
        if ($null -ne $b) { $b.Enabled = -not $busy }
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-JavaDetailZh($info) {
    switch ($info.Status) {
        'ok' {
            $ver = if ($info.Best -and $info.Best.Version) { $info.Best.Version } else { '8' }
            $path = if ($info.Best) { $info.Best.Javaws } else { '' }
            return ("已安装 32 位 Java {0}`r`n{1}" -f $ver, $path)
        }
        'wrong-arch' {
            return "仅检测到 64 位 Java。本 BMC 固件无 64 位 iKVM 库，必须用 32 位 Java 8u51。`r`n建议先卸载 64 位 Java，再安装 32 位。"
        }
        'wrong-ver' {
            if ($info.Detail -eq 'NO_JAVAWS_JAVA9PLUS') {
                return '检测到 Java 目录但缺少 javaws（可能是 Java 9+）。iKVM 需要带 Web Start 的 Java 8。建议卸载后安装 32 位 Java 8u51。'
            }
            $ver = if ($info.Best) { $info.Best.Version } else { '?' }
            $path = if ($info.Best) { $info.Best.Javaws } else { '' }
            return ("已找到 32 位 Java，但不是 8u51: {0}`r`n新版 Java8 会报 JARSigningException（未签名条目）。`r`n请卸载后安装工具自带的 32 位 Java 8u51`r`n{1}" -f $ver, $path)
        }
        default {
            return '未安装 32 位 Java 8u51（需要 javaws）'
        }
    }
}

function Update-JavaStatusUi {
    $info = Get-JavaInstallInfo
    $script:LastJavaInfo = $info
    switch ($info.Status) {
        'ok' {
            $ver = if ($info.Best -and $info.Best.Version) { $info.Best.Version } else { '8' }
            Set-StatusLabel $lblJava ("Java: 32位 {0} 已就绪" -f $ver) 'ok'
        }
        'wrong-arch' {
            Set-StatusLabel $lblJava 'Java: 仅64位(不兼容)，请卸载后装32位8u51' 'bad'
        }
        'wrong-ver' {
            Set-StatusLabel $lblJava 'Java: 版本不对，建议卸载后装32位8u51' 'warn'
        }
        default {
            Set-StatusLabel $lblJava 'Java: 未安装32位8u51（可点「检查/安装Java」）' 'bad'
        }
    }
    return $info
}

function Set-JavaProgress([int]$pct, [string]$text) {
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    $barJava.Value = $pct
    $barJava.Visible = $true
    $lblJavaProg.Text = $text
    $lblJavaProg.Visible = $true
    [System.Windows.Forms.Application]::DoEvents()
}

function Hide-JavaProgress {
    $barJava.Value = 0
    $barJava.Visible = $false
    $lblJavaProg.Text = ''
    $lblJavaProg.Visible = $false
}

function Invoke-JavaCheckOrInstallUi {
    Set-Busy $true
    try {
        Add-Log '正在检查 Java...'
        $info = Update-JavaStatusUi
        $detailZh = Get-JavaDetailZh $info
        Add-Log ($detailZh -replace "`r?`n", ' | ')

        if ($info.Status -eq 'ok') {
            [System.Windows.Forms.MessageBox]::Show(
                ("已安装可用的 32 位 Java，无需重复安装。`r`n`r`n{0}" -f $detailZh),
                'Java 已就绪', 'OK', 'Information') | Out-Null
            Hide-JavaProgress
            return
        }

        if ($info.SuggestUninstall) {
            $r = [System.Windows.Forms.MessageBox]::Show(
                ("{0}`r`n`r`n是否打开「程序和功能」手动卸载错误版本？`r`n（卸载完成后再点本按钮安装 32 位 Java 8u51）" -f $detailZh),
                'Java 版本/架构不对', 'YesNoCancel', 'Warning')
            if ($r -eq [System.Windows.Forms.DialogResult]::Yes) {
                Open-JavaUninstallPanel
                Add-Log '已打开程序和功能，请卸载错误 Java 后重新点击安装'
                return
            }
            if ($r -eq [System.Windows.Forms.DialogResult]::Cancel) { return }
            Add-Log '继续安装 32 位 Java 8u51（可与旧版本并存）'
        } else {
            $r = [System.Windows.Forms.MessageBox]::Show(
                "未检测到 32 位 Java 8u51。`r`n将使用本工具自带/下载的安装包进行安装。`r`n`r`n是否继续？",
                '安装 Java', 'YesNo', 'Question')
            if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
        }

        $installer = Get-BundledJavaInstaller $Root
        if (-not $installer) {
            $cache = Get-JavaInstallerCachePath
            if ((Test-Path $cache) -and ((Get-Item $cache).Length -ge $script:JavaExpectedMinBytes)) {
                $installer = $cache
                Add-Log "使用已下载缓存: $installer"
            }
        } else {
            Add-Log "使用本地安装包: $installer"
            Set-JavaProgress 100 '已找到本地安装包'
        }

        if (-not $installer) {
            $dest = Get-JavaInstallerCachePath
            Add-Log '本地无安装包，开始下载 Java 8u51 (32位)...'
            Set-JavaProgress 0 '准备下载...'
            try {
                $installer = Invoke-JavaInstallerDownloadSync -Destination $dest -OnProgress {
                    param($pct, $recv, $total)
                    $mb = [math]::Round($recv / 1MB, 1)
                    $tmb = if ($total -gt 0) { [math]::Round($total / 1MB, 1) } else { '?' }
                    Set-JavaProgress $pct ("下载 Java 安装包: {0}%  ({1}/{2} MB)" -f $pct, $mb, $tmb)
                }
                try { Copy-JavaInstallerToVendor $installer $Root | Out-Null } catch {}
                Add-Log "下载完成: $installer"
            } catch {
                Hide-JavaProgress
                throw $_
            }
        }

        Set-JavaProgress 100 '正在启动安装程序（静默 /s）...'
        Add-Log '正在静默安装 Java 8u51 32位...'
        $code = Start-JavaSilentInstall $installer
        Add-Log ("安装程序退出码: {0}" -f $code)
        Start-Sleep 2
        $info2 = Update-JavaStatusUi
        if ($info2.Status -eq 'ok') {
            Hide-JavaProgress
            [System.Windows.Forms.MessageBox]::Show(
                ("安装成功。`r`n`r`n{0}" -f (Get-JavaDetailZh $info2)),
                'Java 安装完成', 'OK', 'Information') | Out-Null
        } else {
            Set-JavaProgress 100 '静默安装未检测到，将打开图形安装向导...'
            Add-Log '静默安装后仍未检测到，打开图形安装界面'
            Start-Process -FilePath $installer
            [System.Windows.Forms.MessageBox]::Show(
                "已打开 Java 安装向导，请完成安装后点「检查/安装Java」再确认。`r`n若本机已有错误版本，请先卸载。",
                '请完成安装', 'OK', 'Information') | Out-Null
            Hide-JavaProgress
        }
    } catch {
        Hide-JavaProgress
        Add-Log $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, 'Java 处理失败', 'OK', 'Error') | Out-Null
    } finally { Set-Busy $false }
}

function Update-SettingsHint {
    if (Test-KvmSettingsExists) {
        Set-StatusLabel $lblStore ("设置: 已加密保存`n$((Get-KvmSettingsPath))" ) 'ok'
    } else {
        Set-StatusLabel $lblStore '设置: 尚未保存（密码不会写明文）' 'warn'
    }
}

function Update-CertWindowUi {
    Set-StatusLabel $lblCert (
        ("证书窗口: {0:yyyy-MM-dd} ~ {1:yyyy-MM-dd}  [{2}]" -f $script:CertNotBefore, $script:CertNotAfter, $script:CertSource)
    ) 'info'
    Set-StatusLabel $lblSuggest (
        ("建议BMC时间: {0:yyyy-MM-dd HH:mm:ss}" -f $script:SafeBmcTime)
    ) 'ok'
    $btnTime.Text = ("设为建议时间`n{0:yyyy-MM-dd}" -f $script:SafeBmcTime)
}

function Update-VerifyStatusUi {
    $localPast = (Get-Date) -gt $script:CertNotAfter
    $patchOn = Test-PatcherRunning
    if ($patchOn) {
        Set-StatusLabel $lblPatch '补丁: 运行中' 'ok'
        if ($localPast) {
            Set-StatusLabel $lblVerify 'verify: 本机已过证书结束日，补丁已处理(verify=0)' 'ok'
        } else {
            Set-StatusLabel $lblVerify 'verify: 补丁已运行(verify=0)' 'ok'
        }
    } else {
        Set-StatusLabel $lblPatch '补丁: 未运行' 'warn'
        if ($localPast) {
            Set-StatusLabel $lblVerify 'verify: 本机已过证书结束日，请启动补丁(verify=0)' 'bad'
        } else {
            Set-StatusLabel $lblVerify 'verify: 建议启动自动补丁' 'warn'
        }
    }
}

function Apply-CertWindow($win) {
    if (-not $win) { return }
    $script:CertNotBefore = [datetime]$win.NotBefore
    $script:CertNotAfter = [datetime]$win.NotAfter
    $script:SafeBmcTime = Get-SuggestedBmcTime $script:CertNotBefore $script:CertNotAfter
    $script:CertSource = [string]$win.Source
    Update-CertWindowUi
}

function Import-LegacyIfNeeded {
    if (Test-KvmSettingsExists) { return }
    $legacy = Read-KvmPlainMd $CfgPath
    if (-not $legacy) { return }
    $txtHost.Text = $legacy.Host
    $txtUser.Text = $legacy.User
    $txtPass.Text = $legacy.Password
    $chkHttps.Checked = [bool]$legacy.UseHttps
    Add-Log '检测到旧版 kvm.md 明文，已载入到输入框。请点「保存设置」加密存储，然后可清空明文文件。'
}

function Save-SettingsUi {
    Set-Busy $true
    try {
        $cfg = Get-UiConfig
        $path = Save-KvmSettings -Host $cfg.Host -User $cfg.User -Password $cfg.Pass -UseHttps:$cfg.UseHttps `
            -CertNotBefore $script:CertNotBefore -CertNotAfter $script:CertNotAfter `
            -SuggestedBmcTime $script:SafeBmcTime -CertSource $script:CertSource
        Add-Log "已加密保存到: $path"
        Update-SettingsHint

        $clear = [System.Windows.Forms.MessageBox]::Show(
            "设置已用 Windows DPAPI（当前用户）加密保存。`r`n`r`n是否清除同目录 kvm.md 中的明文账号密码？`r`n（推荐：是）",
            '保存成功', 'YesNo', 'Question')
        if ($clear -eq [System.Windows.Forms.DialogResult]::Yes) {
            if (Clear-KvmLegacyPlaintext $CfgPath) { Add-Log '已清除 kvm.md 明文凭证' }
        }
        [System.Windows.Forms.MessageBox]::Show(
            "已保存。`r`n`r`n说明：密文只能由当前 Windows 用户解密；`r`n换电脑/换用户需重新输入密码。",
            '完成', 'OK', 'Information') | Out-Null
    } catch {
        Add-Log $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '保存失败', 'OK', 'Error') | Out-Null
    } finally { Set-Busy $false }
}

function Start-PatcherUi {
    if (-not (Test-Path $PatchScript)) { throw "缺少 $PatchScript" }
    if (Test-PatcherRunning) {
        Add-Log '补丁脚本已在运行'
        Update-VerifyStatusUi
        return
    }
    Start-Process powershell.exe -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Minimized', '-File', $PatchScript
    ) -WindowStyle Minimized
    Start-Sleep 1
    if (Test-PatcherRunning) {
        Add-Log '已启动 patch-stunnel.ps1（自动 verify=0）'
        Update-VerifyStatusUi
    } else { throw '补丁脚本启动失败' }
}

function Invoke-DiagnoseUi {
    Set-Busy $true
    try {
        Add-Log '开始诊断...'
        $cfg = Get-UiConfig
        Set-StatusLabel $lblBmc "BMC: $($cfg.Host)" 'info'
        Add-Log "目标 $($cfg.Host) / 用户 $($cfg.User)"
        Add-Log ("本机时间: {0:yyyy-MM-dd HH:mm:ss}" -f (Get-Date))

        $ports = @()
        foreach ($p in 80, 443, 5900, 623) {
            if (Test-PortOpen $cfg.Host $p) { $ports += "$p OK"; Add-Log "端口 $p 通" }
            else { $ports += "$p FAIL"; Add-Log "端口 $p 不通" }
        }
        Set-StatusLabel $lblPorts ("端口: " + ($ports -join ' | ')) $(if ($ports -match 'FAIL') { 'warn' } else { 'ok' })

        $jinfo = Update-JavaStatusUi
        Add-Log ("Java: {0}" -f ((Get-JavaDetailZh $jinfo) -replace "`r?`n", ' | '))
        if ($jinfo.Status -ne 'ok') {
            Add-Log '请点击「检查/安装Java」处理'
        }

        $jar = New-CookieJar
        try {
            Invoke-BmcLogin $cfg $jar
            Add-Log 'IPMI 登录成功'

            Add-Log '正在探测 KVM 证书允许时间窗口...'
            $win = Resolve-KvmCertWindow -Cfg $cfg -CookieJar $jar -AllowBmcDownload
            Apply-CertWindow $win
            Add-Log ("证书窗口来源: {0} ({1})" -f $win.Source, $win.Detail)
            Add-Log ("允许范围: {0:yyyy-MM-dd} ~ {1:yyyy-MM-dd}" -f $script:CertNotBefore, $script:CertNotAfter)
            Add-Log ("建议BMC时间: {0:yyyy-MM-dd HH:mm:ss}" -f $script:SafeBmcTime)

            # persist discovered window with current credentials
            Save-KvmSettings -Host $cfg.Host -User $cfg.User -Password $cfg.Pass -UseHttps:$cfg.UseHttps `
                -CertNotBefore $script:CertNotBefore -CertNotAfter $script:CertNotAfter `
                -SuggestedBmcTime $script:SafeBmcTime -CertSource $script:CertSource | Out-Null
            Update-SettingsHint

            $bmcNow = Get-BmcDateTime $cfg $jar
            if ($bmcNow) {
                Add-Log ("BMC 时间: {0:yyyy-MM-dd HH:mm:ss}" -f $bmcNow)
                if ($bmcNow -ge $script:CertNotBefore -and $bmcNow -le $script:CertNotAfter) {
                    Set-StatusLabel $lblTime ("BMC时间: {0:yyyy-MM-dd HH:mm:ss} (证书窗口内)" -f $bmcNow) 'ok'
                } else {
                    Set-StatusLabel $lblTime ("BMC时间: {0:yyyy-MM-dd HH:mm:ss} (超出证书窗口!)" -f $bmcNow) 'bad'
                    Add-Log '请点击「设为建议时间」'
                }
            } else { Set-StatusLabel $lblTime 'BMC时间: 读取失败' 'bad' }

            $pwr = Get-PowerStatus $cfg $jar
            if ($pwr) {
                Set-StatusLabel $lblPower "主机电源: $pwr" $(if ($pwr -eq 'ON') { 'ok' } else { 'warn' })
            }
            $code64 = curl.exe -sS -k -m 8 -b $jar -o NUL -w "%{http_code}" "$($cfg.Base)/libwin_x86_64__V1.0.5.jar.pack.gz"
            if ($code64 -ne '200') { Add-Log "固件无64位库 -> 必须用32位Java" }
        } finally {
            if (Test-Path $jar) {
                curl.exe -sS -k -m 8 -b $jar -o NUL "$($cfg.Base)/cgi/logout.cgi" | Out-Null
                Remove-Item $jar -Force -ErrorAction SilentlyContinue
            }
        }

        Update-VerifyStatusUi
        if (Test-PatcherRunning -and ((Get-Date) -gt $script:CertNotAfter)) {
            Add-Log '本机已过证书结束日，但补丁已运行，verify=0 已处理'
        } elseif (-not (Test-PatcherRunning) -and ((Get-Date) -gt $script:CertNotAfter)) {
            Add-Log '本机已过证书结束日，请先启动 verify 补丁'
        }
        Add-Log '诊断完成'
    } catch {
        Add-Log ("诊断失败: {0}" -f $_.Exception.Message)
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '诊断失败', 'OK', 'Error') | Out-Null
    } finally { Set-Busy $false }
}

function Invoke-FixTimeUi {
    $r = [System.Windows.Forms.MessageBox]::Show(
        ("证书允许: {0:yyyy-MM-dd} ~ {1:yyyy-MM-dd}`r`n来源: {2}`r`n`r`n将 BMC 时间写成建议值:`r`n{3:yyyy-MM-dd HH:mm:ss}" -f `
            $script:CertNotBefore, $script:CertNotAfter, $script:CertSource, $script:SafeBmcTime),
        '确认修改 BMC 时间', 'YesNo', 'Question')
    if ($r -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    Set-Busy $true
    try {
        $cfg = Get-UiConfig
        $jar = New-CookieJar
        try {
            Invoke-BmcLogin $cfg $jar
            $resp = Set-BmcDateTime $cfg $jar $script:SafeBmcTime
            Add-Log "写时间返回: $resp"
            $now = Get-BmcDateTime $cfg $jar
            if ($now) {
                Set-StatusLabel $lblTime ("BMC时间: {0:yyyy-MM-dd HH:mm:ss}" -f $now) `
                    $(if ($now -ge $script:CertNotBefore -and $now -le $script:CertNotAfter) { 'ok' } else { 'bad' })
                Save-KvmSettings -Host $cfg.Host -User $cfg.User -Password $cfg.Pass -UseHttps:$cfg.UseHttps `
                    -CertNotBefore $script:CertNotBefore -CertNotAfter $script:CertNotAfter `
                    -SuggestedBmcTime $script:SafeBmcTime -CertSource $script:CertSource | Out-Null
                [System.Windows.Forms.MessageBox]::Show(("已设置为 {0:yyyy-MM-dd HH:mm:ss}" -f $now), '完成', 'OK', 'Information') | Out-Null
            }
        } finally {
            curl.exe -sS -k -m 8 -b $jar -o NUL "$($cfg.Base)/cgi/logout.cgi" | Out-Null
            Remove-Item $jar -Force -ErrorAction SilentlyContinue
        }
    } catch {
        Add-Log $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '失败', 'OK', 'Error') | Out-Null
    } finally { Set-Busy $false }
}

function Invoke-OpenUi {
    if (-not (Test-Path $OpenScript)) {
        [System.Windows.Forms.MessageBox]::Show("缺少 open-kvm.ps1", '错误', 'OK', 'Error') | Out-Null
        return
    }
    # Ensure encrypted settings exist so open-kvm.ps1 can read them
    try {
        $cfg = Get-UiConfig
        Save-KvmSettings -Host $cfg.Host -User $cfg.User -Password $cfg.Pass -UseHttps:$cfg.UseHttps `
            -CertNotBefore $script:CertNotBefore -CertNotAfter $script:CertNotAfter `
            -SuggestedBmcTime $script:SafeBmcTime -CertSource $script:CertSource | Out-Null
        Add-Log '已同步加密设置（含证书窗口/建议时间）'
        Update-SettingsHint
    } catch {
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '请先填写并保存设置', 'OK', 'Warning') | Out-Null
        return
    }

    Set-Busy $true
    try {
        Start-PatcherUi
        Add-Log '正在启动 KVM...'
        Start-Process powershell.exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $OpenScript)
        [System.Windows.Forms.MessageBox]::Show(
            "已启动。若出现 Java「安全警告」：勾选同意 -> 运行",
            '打开 KVM', 'OK', 'Information') | Out-Null
    } catch {
        Add-Log $_.Exception.Message
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '失败', 'OK', 'Error') | Out-Null
    } finally { Set-Busy $false }
}

function Show-HelpUi {
    $msg = @"
设置安全
- 密码使用 Windows DPAPI（CurrentUser）加密
- 保存位置: %LOCALAPPDATA%\KVM-Tool\settings.json
- 只有同一 Windows 用户能解密；换电脑需重输密码

换电脑
1) 点「检查/安装Java」（自带/自动下载 32 位 8u51）
2) 拷贝本文件夹（含 vendor\jre 安装包更佳）
3) 打开工具填写 IP/账号/密码并保存
4) 诊断 -> 修时间 -> 开补丁 -> 打开KVM
若已装 64 位或其它版本 Java，建议先卸载再装 32 位 8u51

证书窗口会在「完整诊断」时自动探测：
- 优先读最近一次 iKVM 解压的 client/server.crt
- 否则从 BMC 下载 iKVM jar 解析
- 再否则用已保存/内置默认值
建议 BMC 时间 = 证书结束日前约 6 个月（夹在窗口内）
当前建议: {0:yyyy-MM-dd HH:mm:ss}
"@ -f $script:SafeBmcTime
    [System.Windows.Forms.MessageBox]::Show($msg, '说明', 'OK', 'Information') | Out-Null
}

# ---- UI ----
$form = New-Object System.Windows.Forms.Form
$form.Text = 'Supermicro ATEN iKVM 工具'
$form.Size = New-Object Drawing.Size(780, 820)
$form.StartPosition = 'CenterScreen'
$form.MinimumSize = New-Object Drawing.Size(740, 780)
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'KVM 设置 / 诊断 / 打开'
$lblTitle.Font = New-Object Drawing.Font('Microsoft YaHei UI', 14, [Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object Drawing.Point(16, 10)
$lblTitle.AutoSize = $true
$form.Controls.Add($lblTitle)

# settings box
$grp = New-Object System.Windows.Forms.GroupBox
$grp.Text = '连接设置（密码 DPAPI 加密，非明文）'
$grp.Location = New-Object Drawing.Point(16, 44)
$grp.Size = New-Object Drawing.Size(730, 128)
$form.Controls.Add($grp)

function Add-Field([string]$caption, [int]$y, [bool]$password = $false) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $caption
    $l.Location = New-Object Drawing.Point(12, $y)
    $l.Size = New-Object Drawing.Size(70, 22)
    $grp.Controls.Add($l)
    $t = New-Object System.Windows.Forms.TextBox
    $t.Location = New-Object Drawing.Point(90, ($y - 2))
    $t.Size = New-Object Drawing.Size(280, 24)
    if ($password) { $t.UseSystemPasswordChar = $true }
    $grp.Controls.Add($t)
    return $t
}

$txtHost = Add-Field '主机IP' 28
$txtUser = Add-Field '用户名' 58
$txtPass = Add-Field '密码' 88 $true

$chkHttps = New-Object System.Windows.Forms.CheckBox
$chkHttps.Text = '使用 HTTPS 登录网页'
$chkHttps.Location = New-Object Drawing.Point(400, 28)
$chkHttps.Size = New-Object Drawing.Size(200, 22)
$grp.Controls.Add($chkHttps)

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = '保存设置'
$btnSave.Location = New-Object Drawing.Point(400, 58)
$btnSave.Size = New-Object Drawing.Size(120, 32)
$grp.Controls.Add($btnSave)

$lblStore = New-Object System.Windows.Forms.Label
$lblStore.Location = New-Object Drawing.Point(400, 96)
$lblStore.Size = New-Object Drawing.Size(310, 26)
$lblStore.ForeColor = [Drawing.Color]::DimGray
$grp.Controls.Add($lblStore)

# status panel
$panel = New-Object System.Windows.Forms.Panel
$panel.Location = New-Object Drawing.Point(16, 182)
$panel.Size = New-Object Drawing.Size(730, 190)
$panel.BorderStyle = 'FixedSingle'
$form.Controls.Add($panel)

function New-Status([int]$y, [string]$init) {
    $l = New-Object System.Windows.Forms.Label
    $l.Location = New-Object Drawing.Point(10, $y)
    $l.Size = New-Object Drawing.Size(700, 20)
    $l.Text = $init
    $l.ForeColor = [Drawing.Color]::DimGray
    $panel.Controls.Add($l)
    return $l
}
$lblBmc     = New-Status 8   'BMC: (未检测)'
$lblCert    = New-Status 30  '证书窗口: (未探测，点「完整诊断」)'
$lblSuggest = New-Status 52  '建议BMC时间: (未计算)'
$lblTime    = New-Status 74  'BMC时间: (未检测)'
$lblJava    = New-Status 96  'Java: (未检测)'
$lblPatch   = New-Status 118 '补丁: (未检测)'
$lblVerify  = New-Status 140 'verify: (未检测)'
$lblPorts   = New-Status 162 '端口: (未检测)'

$lblPower = New-Object System.Windows.Forms.Label
$lblPower.Location = New-Object Drawing.Point(420, 8)
$lblPower.Size = New-Object Drawing.Size(280, 20)
$lblPower.Text = '主机电源: (未检测)'
$lblPower.ForeColor = [Drawing.Color]::DimGray
$panel.Controls.Add($lblPower)

# action buttons
$y = 386
$w = 140
$g = 10
$x = 16
function New-Btn([string]$text, [int]$bx) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Location = New-Object Drawing.Point($bx, $y)
    $b.Size = New-Object Drawing.Size($w, 40)
    $form.Controls.Add($b)
    return $b
}
$btnDiag  = New-Btn '完整诊断' $x; $x += $w + $g
$btnTime  = New-Btn ("设为建议时间`n{0:yyyy-MM-dd}" -f $script:SafeBmcTime) $x; $x += $w + $g
$btnPatch = New-Btn '启动verify补丁' $x; $x += $w + $g
$btnOpen  = New-Btn '打开KVM' $x; $x += $w + $g
$btnJava  = New-Btn '检查/安装Java' $x

$lblJavaProg = New-Object System.Windows.Forms.Label
$lblJavaProg.Location = New-Object Drawing.Point(16, 434)
$lblJavaProg.Size = New-Object Drawing.Size(730, 18)
$lblJavaProg.ForeColor = [Drawing.Color]::DimGray
$lblJavaProg.Visible = $false
$form.Controls.Add($lblJavaProg)

$barJava = New-Object System.Windows.Forms.ProgressBar
$barJava.Location = New-Object Drawing.Point(16, 454)
$barJava.Size = New-Object Drawing.Size(730, 18)
$barJava.Minimum = 0
$barJava.Maximum = 100
$barJava.Visible = $false
$form.Controls.Add($barJava)

$btnHelp = New-Object System.Windows.Forms.Button
$btnHelp.Text = '说明'
$btnHelp.Location = New-Object Drawing.Point(16, 482)
$btnHelp.Size = New-Object Drawing.Size(90, 28)
$form.Controls.Add($btnHelp)

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = '清空日志'
$btnClear.Location = New-Object Drawing.Point(116, 482)
$btnClear.Size = New-Object Drawing.Size(90, 28)
$form.Controls.Add($btnClear)

$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = '运行日志'
$lblLog.Location = New-Object Drawing.Point(16, 518)
$lblLog.AutoSize = $true
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = 'Vertical'
$txtLog.ReadOnly = $true
$txtLog.Location = New-Object Drawing.Point(16, 540)
$txtLog.Size = New-Object Drawing.Size(730, 180)
$txtLog.Anchor = 'Top,Bottom,Left,Right'
$txtLog.Font = New-Object Drawing.Font('Consolas', 9)
$form.Controls.Add($txtLog)
$script:txtLog = $txtLog

$btnSave.Add_Click({ Save-SettingsUi })
$btnDiag.Add_Click({ Invoke-DiagnoseUi })
$btnTime.Add_Click({ Invoke-FixTimeUi })
$btnPatch.Add_Click({
        Set-Busy $true
        try { Start-PatcherUi } catch {
            Add-Log $_.Exception.Message
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '失败', 'OK', 'Error') | Out-Null
        } finally { Set-Busy $false }
    })
$btnOpen.Add_Click({ Invoke-OpenUi })
$btnJava.Add_Click({ Invoke-JavaCheckOrInstallUi })
$btnHelp.Add_Click({ Show-HelpUi })
$btnClear.Add_Click({ $txtLog.Clear() })

$form.Add_Shown({
        Add-Log "程序目录: $Root"
        Add-Log "加密设置目录: $(Get-KvmSettingsPath)"
        try {
            if (Test-KvmSettingsExists) {
                $s = Load-KvmSettings
                $txtHost.Text = $s.Host
                $txtUser.Text = $s.User
                $txtPass.Text = $s.Password
                $chkHttps.Checked = [bool]$s.UseHttps
                if ($s.CertNotBefore -and $s.CertNotAfter) {
                    $script:CertNotBefore = [datetime]$s.CertNotBefore
                    $script:CertNotAfter = [datetime]$s.CertNotAfter
                    if ($s.SuggestedBmcTime) {
                        $script:SafeBmcTime = [datetime]$s.SuggestedBmcTime
                    } else {
                        $script:SafeBmcTime = Get-SuggestedBmcTime $script:CertNotBefore $script:CertNotAfter
                    }
                    if ($s.CertSource) { $script:CertSource = [string]$s.CertSource }
                    else { $script:CertSource = 'saved-settings' }
                }
                Add-Log '已从加密设置加载连接信息'
            } else {
                Import-LegacyIfNeeded
            }
            Update-CertWindowUi
            Update-SettingsHint
            Update-VerifyStatusUi
            $ji = Update-JavaStatusUi
            Add-Log ("Java检查: {0}" -f $ji.Status)
            $bundled = Get-BundledJavaInstaller $Root
            if ($bundled) { Add-Log "已打包 Java 安装包: $bundled" }
            else { Add-Log '本地尚未打包 Java 安装包（首次安装时会自动下载）' }
        } catch {
            Add-Log $_.Exception.Message
            Set-StatusLabel $lblStore '设置: 解密失败，请重新输入并保存' 'bad'
            Update-CertWindowUi
            Update-VerifyStatusUi
            try { Update-JavaStatusUi | Out-Null } catch {}
        }
    })

[System.Windows.Forms.Application]::Run($form)
