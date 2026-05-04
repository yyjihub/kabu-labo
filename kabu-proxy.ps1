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

function Handle-ProxyRequest([System.Net.HttpListenerContext]$ctx) {
  $req = $ctx.Request
  $res = $ctx.Response

  try {
    # CORS preflight
    if ($req.HttpMethod -eq "OPTIONS") {
      $res.StatusCode = 204
      $res.Headers["Access-Control-Allow-Origin"] = "*"
      $res.Headers["Access-Control-Allow-Methods"] = "GET, OPTIONS"
      $res.Headers["Access-Control-Allow-Headers"] = "Content-Type"
      $res.OutputStream.Close()
      return
    }

    if ($req.HttpMethod -ne "GET") {
      BadRequest $res "method not allowed"
      return
    }

    $path = $req.Url.AbsolutePath

    if ($path -eq "/health") {
      Write-JsonResponse $res 200 ("{""ok"":true,""time"":""$([DateTime]::Now.ToString('o'))""}")
      return
    }

    $q = $req.QueryString
    $symbol = $q["symbol"]

    if ($path -eq "/yahoo/chart-batch") {
      $symbolsParam = $q["symbols"]
      if ([string]::IsNullOrWhiteSpace($symbolsParam)) {
        BadRequest $res "missing symbols"
        return
      }
      if ($symbolsParam.Length -gt 2048 -or $symbolsParam -notmatch '^[A-Za-z0-9\.\-\^=,]+$') {
        BadRequest $res "invalid symbols"
        return
      }

      $interval = $q["interval"]; if ([string]::IsNullOrWhiteSpace($interval)) { $interval = "1d" }
      $range = $q["range"]; if ([string]::IsNullOrWhiteSpace($range)) { $range = "1y" }
      $symbols = $symbolsParam.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries) | Select-Object -First 20
      $requests = @()

      foreach ($sym in $symbols) {
        if ($sym.Length -gt 32 -or $sym -notmatch '^[A-Za-z0-9\.\-\^=]+$') {
          $requests += [pscustomobject]@{ Symbol = $sym; Url = $null; Task = $null; Error = "invalid symbol" }
          continue
        }
        $symbolPath = [System.Uri]::EscapeDataString($sym)
        $chartUrl = "https://query1.finance.yahoo.com/v8/finance/chart/$($symbolPath)?interval=$interval&range=$range"
        $requests += [pscustomobject]@{ Symbol = $sym; Url = $chartUrl; Task = $http.GetAsync($chartUrl); Error = $null }
      }

      $tasks = @($requests | Where-Object { $_.Task -ne $null } | ForEach-Object { $_.Task })
      if ($tasks.Count -gt 0) {
        try { [System.Threading.Tasks.Task]::WaitAll($tasks) } catch {}
      }

      $items = @()
      foreach ($item in $requests) {
        if ($item.Error) {
          $items += [pscustomobject]@{ symbol = $item.Symbol; status = 400; body = $null; error = $item.Error }
          continue
        }

        try {
          $resp = $item.Task.Result
          $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
          $status = [int]$resp.StatusCode
          if ($resp.IsSuccessStatusCode) {
            $items += [pscustomobject]@{ symbol = $item.Symbol; status = 200; body = $body; error = $null }
          } else {
            $snippet = $body
            if ($snippet -and $snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) }
            $snippet = ($snippet -replace "\\s+", " ").Trim()
            $items += [pscustomobject]@{ symbol = $item.Symbol; status = $status; body = $null; error = $snippet }
          }
        } catch {
          $items += [pscustomobject]@{ symbol = $item.Symbol; status = 502; body = $null; error = $_.Exception.Message }
        }
      }

      $payload = ([pscustomobject]@{ result = $items } | ConvertTo-Json -Depth 5 -Compress)
      Write-JsonResponse $res 200 $payload
      return
    } elseif ($path -eq "/yahoo/chart") {
      if ([string]::IsNullOrWhiteSpace($symbol)) {
        BadRequest $res "missing symbol"
        return
      }
      # Chart is a single-symbol endpoint.
      if ($symbol.Length -gt 32 -or $symbol -notmatch '^[A-Za-z0-9\.\-\^=]+$') {
        BadRequest $res "invalid symbol"
        return
      }
      $symbolPath = [System.Uri]::EscapeDataString($symbol)
      $interval = $q["interval"]; if ([string]::IsNullOrWhiteSpace($interval)) { $interval = "1d" }
      $range = $q["range"]; if ([string]::IsNullOrWhiteSpace($range)) { $range = "1y" }
      $url = "https://query1.finance.yahoo.com/v8/finance/chart/$($symbolPath)?interval=$interval&range=$range"
    } elseif ($path -eq "/yahoo/quote") {
      if ([string]::IsNullOrWhiteSpace($symbol)) {
        BadRequest $res "missing symbol"
        return
      }
      # Quote supports comma-separated batches. Keep the allowed characters narrow.
      if ($symbol.Length -gt 2048 -or $symbol -notmatch '^[A-Za-z0-9\.\-\^=,]+$') {
        BadRequest $res "invalid symbol"
        return
      }
      $symbolQuery = [System.Uri]::EscapeDataString($symbol)
      $url = "https://query2.finance.yahoo.com/v7/finance/quote?symbols=$symbolQuery"
    } else {
      BadRequest $res "unknown path"
      return
    }

    try {
      $resp = $http.GetAsync($url).GetAwaiter().GetResult()
      $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      $status = [int]$resp.StatusCode

      if ($resp.IsSuccessStatusCode) {
        Write-JsonResponse $res 200 $body
        return
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
  } catch {
    try {
      $msg = $_.Exception.Message
      Write-JsonResponse $res 500 ("{""error"":""proxy failed"",""detail"":""$msg""}")
    } catch {
      try { $res.OutputStream.Close() } catch {}
    }
  }
}

try {
  while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    Handle-ProxyRequest $ctx
  }
} finally {
  try { $listener.Stop() } catch {}
  try { $listener.Close() } catch {}
  try { $http.Dispose() } catch {}
}
