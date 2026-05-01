@echo off
setlocal
cd /d "%~dp0"

set "PORT=8809"
set "EXPECTED_VERSION=2026-04-25.4"
set "PROXY=%~dp0kabu-lab-proxy.ps1"
set "APP=%~dp0kabu-lab.html"

if not exist "%PROXY%" (
  echo [ERROR] kabu-lab-proxy.ps1 not found.
  pause
  exit /b 1
)

if not exist "%APP%" (
  echo [ERROR] kabu-lab.html not found.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "try { $r = Invoke-WebRequest -UseBasicParsing -TimeoutSec 1 http://127.0.0.1:%PORT%/health; $j = $r.Content | ConvertFrom-Json; if ($r.StatusCode -eq 200 -and $j.version -eq '%EXPECTED_VERSION%') { exit 0 } elseif ($r.StatusCode -eq 200) { exit 2 } else { exit 1 } } catch { exit 1 }"
if "%ERRORLEVEL%"=="0" (
  echo KABU LAB proxy %EXPECTED_VERSION% is already running on port %PORT%.
) else (
  if "%ERRORLEVEL%"=="2" (
    echo [WARN] An older KABU LAB proxy is already running on port %PORT%.
    echo        Close the existing "KABU LAB Proxy" PowerShell window, then run this file again.
    pause
    exit /b 0
  ) else (
    start "KABU LAB Proxy" powershell -NoExit -ExecutionPolicy Bypass -File "%PROXY%" -Port %PORT%
    timeout /t 1 /nobreak >nul
  )
)

start "" "%APP%"
exit /b 0
