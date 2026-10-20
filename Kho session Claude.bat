@echo off
chcp 65001 >nul
title Kho session Claude
rem Tat ban cu dang chay (ke ca ban Node doi truoc) de tranh mo lai trang cu
powershell -NoProfile -Command "Get-NetTCPConnection -LocalPort 4777 -State Listen -ErrorAction SilentlyContinue | Where-Object { $_.OwningProcess -gt 4 } | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force -ErrorAction SilentlyContinue }; Get-CimInstance Win32_Process | Where-Object { $_.Name -eq 'powershell.exe' -and $_.ProcessId -ne $PID -and $_.CommandLine -like '*cs-gui.ps1*' } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }" >nul 2>nul
rem Chay tool bang PowerShell co san trong Windows (khong can cai gi them)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0cs-gui.ps1"
if errorlevel 1 pause
