@echo off
setlocal
cd /d "%~dp0"

set "PORT=8787"
set "HEALTH=http://127.0.0.1:%PORT%/health"

rem If the proxy is already running, do not open another window.
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $r = Invoke-WebRequest -UseBasicParsing '%HEALTH%' -TimeoutSec 1; if ($r.StatusCode -eq 200) { exit 0 } } catch { exit 1 }"
if %ERRORLEVEL%==0 (
  echo kabu proxy is already running on %HEALTH%
  exit /b 0
)

if not exist "%~dp0stock-alert\kabu-proxy.ps1" (
  echo [ERROR] stock-alert\kabu-proxy.ps1 not found.
  pause
  exit /b 1
)

rem Keep the PowerShell window open so errors remain visible instead of disappearing.
start "KABU Proxy :%PORT%" powershell -NoExit -NoProfile -ExecutionPolicy Bypass -File "%~dp0stock-alert\kabu-proxy.ps1" -Port %PORT%
exit /b 0
