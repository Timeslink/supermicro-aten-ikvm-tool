#Requires -Version 5.1
# KVM-Tool one-file installer (extracts embedded payload zip)
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression.FileSystem
[System.Windows.Forms.Application]::EnableVisualStyles()
$ErrorActionPreference = 'Stop'

$DefaultDir = Join-Path $env:LOCALAPPDATA 'KVM-Tool'

function Find-PayloadZip {
    $cands = New-Object System.Collections.Generic.List[string]
    [void]$cands.Add((Join-Path $env:TEMP 'kvm-tool-payload.zip'))
    if ($ScriptRoot) { [void]$cands.Add((Join-Path $ScriptRoot 'kvm-tool-payload.zip')) }
    if ($PSScriptRoot) { [void]$cands.Add((Join-Path $PSScriptRoot 'kvm-tool-payload.zip')) }
    try {
        if ($MyInvocation.MyCommand.Path) {
            [void]$cands.Add((Join-Path (Split-Path $MyInvocation.MyCommand.Path -Parent) 'kvm-tool-payload.zip'))
        }
    } catch {}
    foreach ($p in $cands) {
        if ($p -and (Test-Path -LiteralPath $p) -and ((Get-Item -LiteralPath $p).Length -gt 1MB)) {
            return (Resolve-Path -LiteralPath $p).Path
        }
    }
    return $null
}

function New-Shortcut([string]$linkPath, [string]$targetPath, [string]$workDir, [string]$desc) {
    $w = New-Object -ComObject WScript.Shell
    $s = $w.CreateShortcut($linkPath)
    $s.TargetPath = $targetPath
    $s.WorkingDirectory = $workDir
    $s.Description = $desc
    $s.Save()
}

function Write-UninstallBat([string]$installDir) {
    $bat = @"
@echo off
chcp 65001 >nul
echo Uninstall KVM-Tool from:
echo $installDir
echo.
choice /C YN /M "Delete this folder"
if errorlevel 2 exit /b 0
taskkill /F /IM KVM-Tool-UI.exe >nul 2>&1
rd /s /q "$installDir"
echo Done.
pause
"@
    Set-Content -LiteralPath (Join-Path $installDir '卸载KVM工具.bat') -Value $bat -Encoding UTF8
}

$form = New-Object System.Windows.Forms.Form
$form.Text = 'KVM Tool 安装程序'
$form.Size = New-Object Drawing.Size(560, 420)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$form.Font = New-Object Drawing.Font('Microsoft YaHei UI', 9)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'Supermicro ATEN iKVM 工具 - 安装'
$lblTitle.Font = New-Object Drawing.Font('Microsoft YaHei UI', 12, [Drawing.FontStyle]::Bold)
$lblTitle.Location = New-Object Drawing.Point(20, 16)
$lblTitle.AutoSize = $true
$form.Controls.Add($lblTitle)

$lblInfo = New-Object System.Windows.Forms.Label
$lblInfo.Text = "将安装：KVM 工具、脚本、verify 补丁，以及可选的 32 位 Java 8u51。`r`n复制本安装包到其他电脑即可使用。"
$lblInfo.Location = New-Object Drawing.Point(20, 50)
$lblInfo.Size = New-Object Drawing.Size(500, 40)
$form.Controls.Add($lblInfo)

$lblDir = New-Object System.Windows.Forms.Label
$lblDir.Text = '安装目录'
$lblDir.Location = New-Object Drawing.Point(20, 100)
$lblDir.AutoSize = $true
$form.Controls.Add($lblDir)

$txtDir = New-Object System.Windows.Forms.TextBox
$txtDir.Text = $DefaultDir
$txtDir.Location = New-Object Drawing.Point(20, 122)
$txtDir.Size = New-Object Drawing.Size(400, 24)
$form.Controls.Add($txtDir)

$btnBrowse = New-Object System.Windows.Forms.Button
$btnBrowse.Text = '浏览...'
$btnBrowse.Location = New-Object Drawing.Point(430, 120)
$btnBrowse.Size = New-Object Drawing.Size(90, 28)
$form.Controls.Add($btnBrowse)

$chkDesktop = New-Object System.Windows.Forms.CheckBox
$chkDesktop.Text = '创建桌面快捷方式'
$chkDesktop.Checked = $true
$chkDesktop.Location = New-Object Drawing.Point(20, 160)
$chkDesktop.AutoSize = $true
$form.Controls.Add($chkDesktop)

$chkStart = New-Object System.Windows.Forms.CheckBox
$chkStart.Text = '创建开始菜单快捷方式'
$chkStart.Checked = $true
$chkStart.Location = New-Object Drawing.Point(200, 160)
$chkStart.AutoSize = $true
$form.Controls.Add($chkStart)

$chkJava = New-Object System.Windows.Forms.CheckBox
$chkJava.Text = '若未安装 32 位 Java 8，则自动安装自带的 Java 8u51'
$chkJava.Checked = $true
$chkJava.Location = New-Object Drawing.Point(20, 190)
$chkJava.Size = New-Object Drawing.Size(500, 22)
$form.Controls.Add($chkJava)

$chkLaunch = New-Object System.Windows.Forms.CheckBox
$chkLaunch.Text = '安装完成后打开工具'
$chkLaunch.Checked = $true
$chkLaunch.Location = New-Object Drawing.Point(20, 218)
$chkLaunch.AutoSize = $true
$form.Controls.Add($chkLaunch)

$lblProg = New-Object System.Windows.Forms.Label
$lblProg.Text = '就绪'
$lblProg.Location = New-Object Drawing.Point(20, 255)
$lblProg.Size = New-Object Drawing.Size(500, 20)
$form.Controls.Add($lblProg)

$bar = New-Object System.Windows.Forms.ProgressBar
$bar.Location = New-Object Drawing.Point(20, 280)
$bar.Size = New-Object Drawing.Size(500, 22)
$bar.Minimum = 0
$bar.Maximum = 100
$form.Controls.Add($bar)

$btnInstall = New-Object System.Windows.Forms.Button
$btnInstall.Text = '开始安装'
$btnInstall.Location = New-Object Drawing.Point(280, 330)
$btnInstall.Size = New-Object Drawing.Size(110, 34)
$form.Controls.Add($btnInstall)

$btnClose = New-Object System.Windows.Forms.Button
$btnClose.Text = '关闭'
$btnClose.Location = New-Object Drawing.Point(410, 330)
$btnClose.Size = New-Object Drawing.Size(110, 34)
$form.Controls.Add($btnClose)

function Set-Prog([int]$pct, [string]$text) {
    if ($pct -lt 0) { $pct = 0 }
    if ($pct -gt 100) { $pct = 100 }
    $bar.Value = $pct
    $lblProg.Text = $text
    [System.Windows.Forms.Application]::DoEvents()
}

$btnBrowse.Add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择安装目录'
        $dlg.SelectedPath = $txtDir.Text
        if ($dlg.ShowDialog() -eq 'OK') { $txtDir.Text = $dlg.SelectedPath }
    })

$btnClose.Add_Click({ $form.Close() })

$btnInstall.Add_Click({
        $btnInstall.Enabled = $false
        $btnBrowse.Enabled = $false
        try {
            $installDir = $txtDir.Text.Trim()
            if ([string]::IsNullOrWhiteSpace($installDir)) { throw '请填写安装目录' }

            Set-Prog 5 '查找安装包数据...'
            $zip = Find-PayloadZip
            if (-not $zip) { throw '找不到安装数据包 kvm-tool-payload.zip（安装程序可能未正确打包）' }

            if (-not (Test-Path -LiteralPath $installDir)) {
                New-Item -ItemType Directory -Path $installDir -Force | Out-Null
            }

            Set-Prog 15 '正在解压文件...'
            $tmpExtract = Join-Path $env:TEMP ('kvm_setup_extract_' + [guid]::NewGuid().ToString('N'))
            if (Test-Path $tmpExtract) { Remove-Item $tmpExtract -Recurse -Force }
            New-Item -ItemType Directory -Path $tmpExtract -Force | Out-Null
            [System.IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmpExtract)

            Set-Prog 45 '正在复制到安装目录...'
            Get-ChildItem -LiteralPath $tmpExtract -Force | ForEach-Object {
                $dest = Join-Path $installDir $_.Name
                if ($_.PSIsContainer) {
                    if (Test-Path $dest) { Remove-Item $dest -Recurse -Force -ErrorAction SilentlyContinue }
                    Copy-Item $_.FullName $dest -Recurse -Force
                } else {
                    Copy-Item $_.FullName $dest -Force
                }
            }
            Remove-Item $tmpExtract -Recurse -Force -ErrorAction SilentlyContinue

            $uiExe = Join-Path $installDir 'KVM-Tool-UI.exe'
            if (-not (Test-Path $uiExe)) { throw '安装后缺少 KVM-Tool-UI.exe' }

            Write-UninstallBat $installDir

            if ($chkDesktop.Checked) {
                Set-Prog 60 '创建桌面快捷方式...'
                $desk = [Environment]::GetFolderPath('Desktop')
                New-Shortcut (Join-Path $desk 'KVM工具.lnk') $uiExe $installDir 'Supermicro ATEN iKVM Tool'
            }
            if ($chkStart.Checked) {
                Set-Prog 70 '创建开始菜单快捷方式...'
                $sm = Join-Path ([Environment]::GetFolderPath('StartMenu')) 'Programs\KVM-Tool'
                if (-not (Test-Path $sm)) { New-Item -ItemType Directory -Path $sm -Force | Out-Null }
                New-Shortcut (Join-Path $sm 'KVM工具.lnk') $uiExe $installDir 'Supermicro ATEN iKVM Tool'
            }

            if ($chkJava.Checked) {
                Set-Prog 80 '检查 Java...'
                $javaLib = Join-Path $installDir 'kvm-java.ps1'
                if (Test-Path $javaLib) {
                    . $javaLib
                    $info = Get-JavaInstallInfo
                    if ($info.Status -eq 'ok') {
                        Set-Prog 90 '本机已有 Java 8u51，跳过安装'
                        try { Repair-AtenJavaForIkvm | Out-Null } catch {}
                    } else {
                        if ($info.SuggestUninstall) {
                            Set-Prog 82 '检测到非 8u51 Java，建议先卸载再装（将继续尝试安装 8u51）...'
                        }
                        $installer = Get-BundledJavaInstaller $installDir
                        if (-not $installer) { $installer = Join-Path $installDir 'vendor\jre-8u51-windows-i586.exe' }
                        if (Test-Path $installer) {
                            Set-Prog 85 '正在安装 32 位 Java 8u51（静默）...'
                            $code = Start-JavaSilentInstall $installer
                            Set-Prog 95 ("Java 安装退出码: $code，复查中...")
                            Start-Sleep 2
                            $info2 = Get-JavaInstallInfo
                            if ($info2.Status -ne 'ok') {
                                Start-Process -FilePath $installer
                                [System.Windows.Forms.MessageBox]::Show(
                                    "需要精确的 32 位 Java 8u51。`r`n新版 Java8 会导致 JARSigningException。`r`n已打开安装向导；若本机有其它 Java，请先在程序和功能中卸载。",
                                    'Java', 'OK', 'Information') | Out-Null
                            } else {
                                try { Repair-AtenJavaForIkvm | Out-Null } catch {}
                            }
                        }
                    }
                }
            }

            Set-Prog 100 '安装完成'
            [System.Windows.Forms.MessageBox]::Show(
                ("安装完成。`r`n`r`n目录: {0}`r`n`r`n下一步: 打开工具 -> 填写 BMC IP/账号/密码 -> 保存 -> 诊断 -> 打开KVM" -f $installDir),
                '完成', 'OK', 'Information') | Out-Null

            if ($chkLaunch.Checked -and (Test-Path $uiExe)) {
                Start-Process -FilePath $uiExe -WorkingDirectory $installDir
            }
            $form.Close()
        } catch {
            [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, '安装失败', 'OK', 'Error') | Out-Null
            Set-Prog 0 ('失败: ' + $_.Exception.Message)
            $btnInstall.Enabled = $true
            $btnBrowse.Enabled = $true
        }
    })

[System.Windows.Forms.Application]::Run($form)
