@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-update.ps1"
if %errorlevel% neq 0 (
    echo.
    echo Script exited with error code %errorlevel%
    pause
)
