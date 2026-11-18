@echo off
chcp 65001 >nul
cd /d "%~dp0"
if exist "%~dp0KVM-Tool-UI.exe" (
  start "" "%~dp0KVM-Tool-UI.exe"
) else if exist "%~dp0KVM-Tool.exe" (
  start "" "%~dp0KVM-Tool.exe"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0kvm-tool-ui.ps1"
)
