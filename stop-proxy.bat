@echo off
setlocal
cd /d "%~dp0"

set "TARGET=stock-alert\kabu-proxy.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -Command ^
  "$procs = Get-CimInstance Win32_Process | Where-Object { ($_.Name -match '^(powershell|pwsh)\\.exe$') -and ($_.CommandLine -like '*'+$env:TARGET+'*') }; if (-not $procs) { Write-Host 'Proxy process not found.'; exit 0 }; $procs | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue; Write-Host ('Stopped PID ' + $_.ProcessId) }"

exit /b 0
