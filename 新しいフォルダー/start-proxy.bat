@echo off
setlocal
cd /d "%~dp0"

set "PORT=8787"
set "PS_FILE=%~dp0kabu-proxy.ps1"

if not exist "%PS_FILE%" (
  echo [ERROR] kabu-proxy.ps1 not found.
  pause
  exit /b 1
)

rem If health endpoint responds, do not start duplicate process.
powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 http://127.0.0.1:%PORT%/health; if ($r.StatusCode -eq 200) { exit 0 } else { exit 1 } } catch { exit 1 }"
if %ERRORLEVEL%==0 (
  echo Proxy is already running on port %PORT%.
  exit /b 0
)

start "kabu-proxy" powershell -NoExit -ExecutionPolicy Bypass -File "%PS_FILE%" -Port %PORT%
exit /b 0