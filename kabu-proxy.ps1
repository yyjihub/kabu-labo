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
$UpstreamTimeoutSeconds = 20
$BatchTimeoutSeconds = 24

# Ensure TLS 1.2 for older Windows/.NET
try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

$null = Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
$http = [System.Net.Http.HttpClient]::new()
$http.Timeout = [TimeSpan]::FromSeconds($UpstreamTimeoutSeconds)
$http.DefaultRequestHeaders.UserAgent.ParseAdd("kabu-proxy/1.0")

function Get-ReasonPhrase([int]$status) {
  switch ($status) {
    200 { "OK" }
    204 { "No Content" }
    400 { "Bad Request" }
    500 { "Internal Server Error" }
    502 { "Bad Gateway" }
    504 { "Gateway Timeout" }
    default { "OK" }
  }
}

function Write-JsonResponse([System.IO.Stream]$stream, [int]$status, [string]$body) {
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($body)
  $reason = Get-ReasonPhrase $status
  $headers = @(
    "HTTP/1.1 $status $reason",
    "Content-Type: application/json; charset=utf-8",
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Methods: GET, OPTIONS",
    "Access-Control-Allow-Headers: Content-Type",
    "Content-Length: $($bytes.Length)",
    "Connection: close",
    "",
    ""
  ) -join "`r`n"
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
  $stream.Write($headerBytes, 0, $headerBytes.Length)
  if ($bytes.Length -gt 0) {
    $stream.Write($bytes, 0, $bytes.Length)
  }
}

function Write-NoContent([System.IO.Stream]$stream) {
  $headers = @(
    "HTTP/1.1 204 No Content",
    "Access-Control-Allow-Origin: *",
    "Access-Control-Allow-Methods: GET, OPTIONS",
    "Access-Control-Allow-Headers: Content-Type",
    "Content-Length: 0",
    "Connection: close",
    "",
    ""
  ) -join "`r`n"
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
  $stream.Write($bytes, 0, $bytes.Length)
}

function BadRequest([System.IO.Stream]$stream, [string]$msg) {
  Write-JsonResponse $stream 400 ("{""error"":""$msg""}")
}

function Parse-QueryString([string]$query) {
  $result = @{}
  if ([string]::IsNullOrWhiteSpace($query)) { return $result }
  $raw = $query
  if ($raw.StartsWith("?")) { $raw = $raw.Substring(1) }
  foreach ($pair in $raw.Split("&", [System.StringSplitOptions]::RemoveEmptyEntries)) {
    $kv = $pair.Split("=", 2)
    $key = [System.Uri]::UnescapeDataString($kv[0].Replace("+", " "))
    $value = ""
    if ($kv.Length -gt 1) {
      $value = [System.Uri]::UnescapeDataString($kv[1].Replace("+", " "))
    }
    $result[$key] = $value
  }
  return $result
}

function Find-HeaderEnd([byte[]]$bytes) {
  for ($i = 0; $i -le $bytes.Length - 4; $i++) {
    if ($bytes[$i] -eq 13 -and $bytes[$i + 1] -eq 10 -and $bytes[$i + 2] -eq 13 -and $bytes[$i + 3] -eq 10) {
      return $i
    }
  }
  return -1
}

function Read-HttpRequest([System.Net.Sockets.TcpClient]$client) {
  $stream = $client.GetStream()
  if ($stream.CanTimeout) {
    $stream.ReadTimeout = 10000
    $stream.WriteTimeout = 20000
  }
  $buffer = New-Object byte[] 8192
  $memory = [System.IO.MemoryStream]::new()
  $headerEnd = -1
  while ($headerEnd -lt 0) {
    $read = $stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) { break }
    $memory.Write($buffer, 0, $read)
    $headerEnd = Find-HeaderEnd $memory.ToArray()
    if ($memory.Length -gt 262144) { throw "request headers too large" }
  }
  if ($headerEnd -lt 0) { throw "request headers incomplete" }
  $headerText = [System.Text.Encoding]::ASCII.GetString($memory.ToArray(), 0, $headerEnd)
  $lines = $headerText -split "`r`n"
  if ($lines.Length -eq 0 -or [string]::IsNullOrWhiteSpace($lines[0])) { throw "bad request line" }
  $parts = $lines[0].Split(" ")
  if ($parts.Length -lt 2) { throw "bad request" }
  return [ordered]@{
    Stream = $stream
    Method = $parts[0].ToUpperInvariant()
    Target = $parts[1]
  }
}

Write-Host "kabu-proxy listening on http://127.0.0.1:$Port/ (Ctrl+C to stop)"

function Handle-ProxyRequest([string]$Method, [string]$Path, [hashtable]$Query, [System.IO.Stream]$Stream) {

  try {
    # CORS preflight
    if ($Method -eq "OPTIONS") {
      Write-NoContent $Stream
      return
    }

    if ($Method -ne "GET") {
      BadRequest $Stream "method not allowed"
      return
    }

    if ($Path -eq "/health") {
      Write-JsonResponse $Stream 200 ("{""ok"":true,""time"":""$([DateTime]::Now.ToString('o'))""}")
      return
    }

    $q = $Query
    $symbol = $q["symbol"]

    if ($Path -eq "/yahoo/chart-batch") {
      $symbolsParam = $q["symbols"]
      if ([string]::IsNullOrWhiteSpace($symbolsParam)) {
        BadRequest $Stream "missing symbols"
        return
      }
      if ($symbolsParam.Length -gt 2048 -or $symbolsParam -notmatch '^[A-Za-z0-9\.\-\^=,]+$') {
        BadRequest $Stream "invalid symbols"
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
        try { [void][System.Threading.Tasks.Task]::WaitAll($tasks, [TimeSpan]::FromSeconds($BatchTimeoutSeconds)) } catch {}
      }

      $items = @()
      foreach ($item in $requests) {
        if ($item.Error) {
          $items += [pscustomobject]@{ symbol = $item.Symbol; status = 400; body = $null; error = $item.Error }
          continue
        }

        try {
          if (-not $item.Task.IsCompleted) {
            $items += [pscustomobject]@{ symbol = $item.Symbol; status = 504; body = $null; error = "upstream timeout" }
            continue
          }
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
      Write-JsonResponse $Stream 200 $payload
      return
    } elseif ($Path -eq "/yahoo/chart") {
      if ([string]::IsNullOrWhiteSpace($symbol)) {
        BadRequest $Stream "missing symbol"
        return
      }
      # Chart is a single-symbol endpoint.
      if ($symbol.Length -gt 32 -or $symbol -notmatch '^[A-Za-z0-9\.\-\^=]+$') {
        BadRequest $Stream "invalid symbol"
        return
      }
      $symbolPath = [System.Uri]::EscapeDataString($symbol)
      $interval = $q["interval"]; if ([string]::IsNullOrWhiteSpace($interval)) { $interval = "1d" }
      $range = $q["range"]; if ([string]::IsNullOrWhiteSpace($range)) { $range = "1y" }
      $url = "https://query1.finance.yahoo.com/v8/finance/chart/$($symbolPath)?interval=$interval&range=$range"
    } elseif ($Path -eq "/yahoo/quote") {
      if ([string]::IsNullOrWhiteSpace($symbol)) {
        BadRequest $Stream "missing symbol"
        return
      }
      # Quote supports comma-separated batches. Keep the allowed characters narrow.
      if ($symbol.Length -gt 2048 -or $symbol -notmatch '^[A-Za-z0-9\.\-\^=,]+$') {
        BadRequest $Stream "invalid symbol"
        return
      }
      $symbolQuery = [System.Uri]::EscapeDataString($symbol)
      $url = "https://query2.finance.yahoo.com/v7/finance/quote?symbols=$symbolQuery"
    } else {
      BadRequest $Stream "unknown path"
      return
    }

    try {
      $resp = $http.GetAsync($url).GetAwaiter().GetResult()
      $body = $resp.Content.ReadAsStringAsync().GetAwaiter().GetResult()
      $status = [int]$resp.StatusCode

      if ($resp.IsSuccessStatusCode) {
        Write-JsonResponse $Stream 200 $body
        return
      }

      $snippet = $body
      if ($snippet -and $snippet.Length -gt 300) { $snippet = $snippet.Substring(0, 300) }
      $snippet = ($snippet -replace "\\s+", " ").Trim()

      $payload = "{""error"":""upstream status"",""upstreamStatus"":""$status"",""url"":""$url"",""body"":""$snippet""}"
      Write-JsonResponse $Stream 502 $payload
    } catch {
      $msg = $_.Exception.Message
      $payload = "{""error"":""upstream failed"",""detail"":""$msg"",""url"":""$url""}"
      Write-JsonResponse $Stream 502 $payload
    }
  } catch {
    try {
      $msg = $_.Exception.Message
      Write-JsonResponse $Stream 500 ("{""error"":""proxy failed"",""detail"":""$msg""}")
    } catch {
    }
  }
}

$listener = $null
try {
  $ip = [System.Net.IPAddress]::Parse("127.0.0.1")
  $listener = [System.Net.Sockets.TcpListener]::new($ip, $Port)
  $listener.Start()

  while ($true) {
    $client = $listener.AcceptTcpClient()
    $client.NoDelay = $true
    $client.ReceiveTimeout = 10000
    $client.SendTimeout = 20000
    $stream = $null
    try {
      $request = Read-HttpRequest $client
      $stream = $request.Stream
      $uri = [System.Uri]::new("http://127.0.0.1:$Port$($request.Target)")
      $query = Parse-QueryString $uri.Query
      Handle-ProxyRequest -Method $request.Method -Path $uri.AbsolutePath -Query $query -Stream $stream
    } catch {
      try {
        if ($stream) {
          $msg = $_.Exception.Message
          Write-JsonResponse $stream 502 ("{""error"":""proxy failed"",""detail"":""$msg""}")
        }
      } catch {}
    } finally {
      try { $client.Close() } catch {}
    }
  }
} finally {
  try { if ($listener) { $listener.Stop() } } catch {}
  try { $http.Dispose() } catch {}
}
