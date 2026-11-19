@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0P4AutoMerge.ps1"
if errorlevel 1 pause
