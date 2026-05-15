@echo off
setlocal

if "%~1"=="" (
    echo Usage: %~nx0 ^<version^>
    echo Example: %~nx0 1.0
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Build-Installer.ps1" -Version "%~1"
exit /b %ERRORLEVEL%
