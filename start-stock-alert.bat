@echo off
setlocal
cd /d "%~dp0"

call "%~dp0start-proxy.bat"

rem Wait briefly so the proxy can boot.
timeout /t 1 /nobreak >nul

if exist "%~dp0stock-alert.html" (
  start "" "%~dp0stock-alert.html"
) else (
  echo [ERROR] stock-alert.html not found.
  pause
)

exit /b 0