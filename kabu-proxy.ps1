# Simple local proxy to avoid CORS issues for Yahoo Finance endpoints.
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\kabu-proxy.ps1
#   powershell -ExecutionPolicy Bypass -File .\kabu-proxy.ps1 -Port 8788
# Health:
#   http://127.0.0.1:<port>/health

param(
  [int]$Port = 8787
)

$ErrorActionPreference = "Stop"

# Ensure TLS 1.2 for older Windows/.NET
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

$prefix = "http://127.0.0.1:$Port/"
$listener = New-Object System.Net.HttpListener
$listener.Prefixes.Add($prefix)

$null = Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
$http = [System.Net.Http.HttpClient]::new()
$http.Timeout = [TimeSpan]::FromSeconds(30)
$http.DefaultRequestHeaders.UserAgent.ParseAdd("kabu-proxy/1.0")

function Write-JsonResponse([System.Net.HttpListenerResponse]$res, [int]$status, [string]$body) {
  $res.StatusCode = $status
  $res.ContentType = "application/json; charset=utf-8"
  $res.Headers["Access-Control-Allow-Origin"] = "*"
  $res.Headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
  $res.Headers["Access-Control-Allow-Headers"] = "Content-Type"
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  $res.ContentLength64 = $bytes.Length
  $res.OutputStream.Write($bytes, 0, $bytes.Length)
  $res.OutputStream.Close()
}

function BadRequest([System.Net.HttpListenerResponse]$res, [string]$msg) {
  Write-JsonResponse $res 400 ("{""error"":""$msg""}")
}

try {
  $listener.Start()
} catch {
  Write-Host "Failed to start HttpListener on $prefix"
  Write-Host $_.Exception.Message
  Write-Host ""
  Write-Host "Common fixes:"
  Write-Host "- Try another port: powershell -ExecutionPolicy Bypass -File .\\kabu-proxy.ps1 -Port 8788"
  Write-Host "- If you see Access is denied, run PowerShell as Administrator OR reserve URLACL. Example (Admin):"
  Write-Host "  netsh http add urlacl url=$prefix user=$env:UserName"
  throw
}

Write-Host "kabu-proxy listening on $prefix (Ctrl+C to stop)"

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $req = $ctx.Request
    $res = $ctx.Response

    # CORS preflight
    if ($req.HttpMethod -eq "OPTIONS") {
      $res.StatusCode = 204
      $res.Headers["Access-Control-Allow-Origin"] = "*"
      $res.Headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
      $res.Headers["Access-Control-Allow-Headers"] = "Content-Type"
      $res.OutputStream.Close()
      continue
    }

    if ($req.HttpMethod -ne "GET") {
      BadRequest $res "method not allowed"
      continue
    }

    $path = $req.Url.AbsolutePath

    if ($path -eq "/health") {
      Write-JsonResponse $res 200 ("{""ok"":true,""time"":""$([DateTime]::Now.ToString('o'))""}")
      continue
    }

    $q = $req.QueryString
    $symbol = $q["symbol"]

    if ($path -eq "/yahoo/chart") {
      if ([string]::IsNullOrWhiteSpace($symbol)) {
        BadRequest $res "missing symbol"
        continue
      }
      # Chart is a single-symbol endpoint.
      if ($symbol.Length -gt 32 -or $symbol -notmatch '^[A-Za-z0-9\.\-\^=]+$') {
        BadRequest $res "invalid symbol"
        continue
      }
      $symbolPath = [System.Uri]::EscapeDataString($symbol)
      $interval = $q["interval"]; if ([string]::IsNullOrWhiteSpace($interval)) { $interval = "1d" }
      $range = $q["range"]; if ([string]::IsNullOrWhiteSpace($range)) { $range = "1y" }
      $url = "https://query1.finance.yahoo.com/v8/finance/chart/$($symbolPath)?interval=$interval&range=$range"
    } elseif ($path -eq "/yahoo/quote") {
      if ([string]::IsNullOrWhiteSpace($symbol)) {
        BadRequest $res "missing symbol"
        continue
      }
      # Quote supports comma-separated batches. Keep the allowed characters narrow.
      if ($symbol.Length -gt 2048 -or $symbol -notmatch '^[A-Za-z0-9\.\-\^=,]+$') {
        BadRequest $res "invalid symbol"
        continue
      }
      $symbolQuery = [System.Uri]::EscapeDataString($symbol)
      $url = "https://query2.finance.yahoo.com/v7/finance/quote?symbols=$symbolQuery"
    } else {
      BadRequest $res "unknown path"
      continue
    }

    try {
      $resp = $http.GetAsync($url).GetAwaiter().GetResult()
      $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      $status = [int]$resp.StatusCode

      if ($resp.IsSuccessStatusCode) {
        Write-JsonResponse $res 200 $body
        continue
      }

      $snippet = $body
      if ($snippet -and $snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) }
      $snippet = ($snippet -replace "\\s+", " ").Trim()

      $payload = "{""error"":""upstream status"",""upstreamStatus"":""$status"",""url"":""$url"",""body"":""$snippet""}"
      Write-JsonResponse $res 502 $payload
    } catch {
      $msg = $_.Exception.Message
      $payload = "{""error"":""upstream failed"",""detail"":""$msg"",""url"":""$url""}"
      Write-JsonResponse $res 502 $payload
    }
  }
} finally {
  try { $listener.Stop() } catch {}
  try { $listener.Close() } catch {}
  try { $http.Dispose() } catch {}
}
