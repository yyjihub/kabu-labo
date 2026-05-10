# Local data proxy for KABU LAB.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File .\kabu-lab-proxy.ps1
#   powershell -ExecutionPolicy Bypass -File .\kabu-lab-proxy.ps1 -Port 8791
#
# Endpoints:
#   /health
#   /yahoo/quote?symbol=7203.T,AAPL
#   /yahoo/chart?symbol=7203.T&range=1y&interval=1d
#   /tdnet/ir?code=7203&days=31
#   /ir/pdf-text?url=https%3A%2F%2F...
#   /jpx/earnings?code=7203
#   /name?code=7203&market=JP
#   /news/morning?codes=7203,6758&days=3

param(
  [int]$Port = 8791
)

$ErrorActionPreference = "Stop"
$ProxyVersion = "2026-05-09.1"
$ClientReadTimeoutMs = 10000
$ClientWriteTimeoutMs = 20000
$JpxEarningsPageUrl = "https://www.jpx.co.jp/listing/event-schedules/financial-announcement/index.html"
$JpxEarningsMaxBytes = 8 * 1024 * 1024
$script:JpxEarningsCache = $null

$NewsFetcherDir = Join-Path $PSScriptRoot "news-fetchers"
foreach ($moduleName in @("Common.ps1", "TdnetFetcher.ps1", "EdinetFetcher.ps1", "YahooFinanceFetcher.ps1", "XFetcher.ps1", "PriceRankingFetcher.ps1", "MorningNewsAggregator.ps1")) {
  $modulePath = Join-Path $NewsFetcherDir $moduleName
  if (-not (Test-Path -LiteralPath $modulePath)) { throw "missing news fetcher module: $moduleName" }
  . $modulePath
}

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

try {
  [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
} catch {}

try {
  Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
  Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
} catch {}

$null = Add-Type -AssemblyName System.Net.Http -ErrorAction SilentlyContinue
$handler = [System.Net.Http.HttpClientHandler]::new()
try {
  $handler.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
} catch {}

$http = [System.Net.Http.HttpClient]::new($handler)
$http.Timeout = [TimeSpan]::FromSeconds(35)
$http.DefaultRequestHeaders.UserAgent.ParseAdd("Mozilla/5.0 (Windows NT 10.0; Win64; x64) KABU-LAB/1.0")
$http.DefaultRequestHeaders.Accept.ParseAdd("application/json, text/html, */*")

function Get-ReasonPhrase {
  param([int]$Status)
  switch ($Status) {
    200 { "OK" }
    204 { "No Content" }
    401 { "Unauthorized" }
    400 { "Bad Request" }
    404 { "Not Found" }
    405 { "Method Not Allowed" }
    502 { "Bad Gateway" }
    default { "OK" }
  }
}

function Send-Body {
  param(
    [System.IO.Stream]$Stream,
    [int]$Status,
    [string]$Body,
    [string]$ContentType = "application/json; charset=utf-8"
  )

  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
  $reason = Get-ReasonPhrase $Status
  $headers = @(
    "HTTP/1.1 $Status $reason",
    "Content-Type: $ContentType",
    "Access-Control-Allow-Origin: null",
    "Vary: Origin",
    "Access-Control-Allow-Methods: GET, OPTIONS",
    "Access-Control-Allow-Headers: Content-Type",
    "Content-Length: $($bodyBytes.Length)",
    "Connection: close",
    "",
    ""
  ) -join "`r`n"
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
  $Stream.Write($headerBytes, 0, $headerBytes.Length)
  if ($bodyBytes.Length -gt 0) {
    $Stream.Write($bodyBytes, 0, $bodyBytes.Length)
  }
}

function Send-Json {
  param(
    [System.IO.Stream]$Stream,
    [int]$Status,
    [object]$Payload
  )
  $json = $Payload | ConvertTo-Json -Depth 12 -Compress
  Send-Body $Stream $Status $json
}

function Send-NoContent {
  param([System.IO.Stream]$Stream)
  $headers = @(
    "HTTP/1.1 204 No Content",
    "Access-Control-Allow-Origin: null",
    "Vary: Origin",
    "Access-Control-Allow-Methods: GET, OPTIONS",
    "Access-Control-Allow-Headers: Content-Type",
    "Content-Length: 0",
    "Connection: close",
    "",
    ""
  ) -join "`r`n"
  $bytes = [System.Text.Encoding]::ASCII.GetBytes($headers)
  $Stream.Write($bytes, 0, $bytes.Length)
}

function Parse-QueryString {
  param([string]$Query)

  $result = @{}
  if ([string]::IsNullOrWhiteSpace($Query)) { return $result }
  $raw = $Query
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

function Split-ListQueryValue {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
  return @($Value.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries) | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-DeepErrorMessage {
  param([object]$ErrorObject)

  $ex = $ErrorObject
  if ($ErrorObject -is [System.Management.Automation.ErrorRecord]) {
    $ex = $ErrorObject.Exception
  }
  $messages = New-Object System.Collections.Generic.List[string]
  while ($ex) {
    if ($ex.Message) { $messages.Add($ex.Message) }
    $ex = $ex.InnerException
  }
  if ($messages.Count -eq 0) { return "unknown error" }
  return ($messages -join " -> ")
}

function Invoke-UpstreamJson {
  param([string]$Url)

  $errors = New-Object System.Collections.Generic.List[string]

  try {
    $response = $http.GetAsync($Url).GetAwaiter().GetResult()
    $body = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if ($response.IsSuccessStatusCode) { return $body }
    $snippet = ($body -replace "\s+", " ").Trim()
    if ($snippet.Length -gt 500) { $snippet = $snippet.Substring(0, 500) }
    $errors.Add("HttpClient status $([int]$response.StatusCode): $snippet")
  } catch {
    $errors.Add("HttpClient: $(Get-DeepErrorMessage $_)")
  }

  try {
    $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 35 -Uri $Url -Headers @{
      "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) KABU-LAB/1.0"
      "Accept" = "application/json, text/plain, */*"
    }
    return [string]$response.Content
  } catch {
    $errors.Add("Invoke-WebRequest: $(Get-DeepErrorMessage $_)")
  }

  throw ($errors -join " | ")
}

function Invoke-UpstreamJsonAny {
  param([string[]]$Urls)

  $errors = New-Object System.Collections.Generic.List[string]
  foreach ($url in $Urls) {
    try {
      return Invoke-UpstreamJson $url
    } catch {
      $errors.Add("$url :: $(Get-DeepErrorMessage $_)")
    }
  }
  throw ($errors -join " | ")
}

function Invoke-UpstreamText {
  param(
    [string]$Url,
    [string]$EncodingName = "UTF-8"
  )

  $errors = New-Object System.Collections.Generic.List[string]
  $bytes = $null

  try {
    $response = $http.GetAsync($Url).GetAwaiter().GetResult()
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    if (-not $response.IsSuccessStatusCode) {
      throw "HttpClient status $([int]$response.StatusCode)"
    }
  } catch {
    $errors.Add("HttpClient: $(Get-DeepErrorMessage $_)")
    $bytes = $null
  }

  if ($null -eq $bytes) {
    try {
      $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 35 -Uri $Url -Headers @{
        "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) KABU-LAB/1.0"
        "Accept" = "text/html,text/csv,text/plain,*/*"
      }
      if ($response.RawContentStream) {
        $ms = [System.IO.MemoryStream]::new()
        $response.RawContentStream.CopyTo($ms)
        $bytes = $ms.ToArray()
      } else {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes([string]$response.Content)
      }
    } catch {
      $errors.Add("Invoke-WebRequest: $(Get-DeepErrorMessage $_)")
    }
  }

  if ($null -eq $bytes) {
    throw ($errors -join " | ")
  }

  if ($EncodingName -eq "Shift_JIS") {
    try {
      return [System.Text.Encoding]::GetEncoding(932).GetString($bytes)
    } catch {
      return [System.Text.Encoding]::UTF8.GetString($bytes)
    }
  }
  return [System.Text.Encoding]::UTF8.GetString($bytes)
}

function Invoke-UpstreamBytes {
  param([string]$Url)

  $errors = New-Object System.Collections.Generic.List[string]
  try {
    $response = $http.GetAsync($Url).GetAwaiter().GetResult()
    $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
    if ($response.IsSuccessStatusCode) { return $bytes }
    $errors.Add("HttpClient status $([int]$response.StatusCode)")
  } catch {
    $errors.Add("HttpClient: $(Get-DeepErrorMessage $_)")
  }

  try {
    $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 35 -Uri $Url -Headers @{
      "User-Agent" = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) KABU-LAB/1.0"
      "Accept" = "application/pdf,*/*"
    }
    if ($response.RawContentStream) {
      $ms = [System.IO.MemoryStream]::new()
      $response.RawContentStream.CopyTo($ms)
      return $ms.ToArray()
    }
    if ($response.Content -is [byte[]]) { return [byte[]]$response.Content }
    return [System.Text.Encoding]::GetEncoding("ISO-8859-1").GetBytes([string]$response.Content)
  } catch {
    $errors.Add("Invoke-WebRequest: $(Get-DeepErrorMessage $_)")
  }

  throw ($errors -join " | ")
}

function ConvertTo-YahooChartFromStooq {
  param(
    [string]$Symbol,
    [string]$Range
  )

  $stooqSymbol = $Symbol.ToLowerInvariant()
  if ($stooqSymbol.EndsWith(".t")) {
    $stooqSymbol = $stooqSymbol.Substring(0, $stooqSymbol.Length - 2) + ".jp"
  } elseif ($stooqSymbol -notmatch "\.") {
    $stooqSymbol = "$stooqSymbol.us"
  }

  $days = 370
  if ($Range -match "^([0-9]+)d$") { $days = [int]$Matches[1] + 10 }
  elseif ($Range -match "^([0-9]+)m$") { $days = ([int]$Matches[1] * 31) + 10 }
  elseif ($Range -match "^([0-9]+)y$") { $days = ([int]$Matches[1] * 366) + 10 }
  elseif ($Range -eq "max") { $days = 3650 }

  $d2 = (Get-Date).ToString("yyyyMMdd")
  $d1 = (Get-Date).AddDays(-$days).ToString("yyyyMMdd")
  $url = "https://stooq.com/q/d/l/?s=$([System.Uri]::EscapeDataString($stooqSymbol))&d1=$d1&d2=$d2&i=d"
  $csvText = Invoke-UpstreamText -Url $url -EncodingName "UTF-8"
  $rows = $csvText -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -notmatch "^Date," }

  $timestamps = New-Object System.Collections.Generic.List[int64]
  $open = New-Object System.Collections.Generic.List[object]
  $high = New-Object System.Collections.Generic.List[object]
  $low = New-Object System.Collections.Generic.List[object]
  $close = New-Object System.Collections.Generic.List[object]
  $volume = New-Object System.Collections.Generic.List[object]

  foreach ($row in $rows) {
    $cols = $row.Split(",")
    if ($cols.Length -lt 6) { continue }
    if ($cols[1] -eq "N/D" -or $cols[4] -eq "N/D") { continue }
    $dt = [DateTime]::ParseExact($cols[0], "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
    $dto = [DateTimeOffset]::new($dt.Year, $dt.Month, $dt.Day, 0, 0, 0, [TimeSpan]::Zero)
    $timestamps.Add($dto.ToUnixTimeSeconds())
    $open.Add([double]::Parse($cols[1], [Globalization.CultureInfo]::InvariantCulture))
    $high.Add([double]::Parse($cols[2], [Globalization.CultureInfo]::InvariantCulture))
    $low.Add([double]::Parse($cols[3], [Globalization.CultureInfo]::InvariantCulture))
    $close.Add([double]::Parse($cols[4], [Globalization.CultureInfo]::InvariantCulture))
    $volVal = $null
    if ($cols[5] -ne "N/D" -and $cols[5] -ne "") {
      $volVal = [int64]::Parse($cols[5], [Globalization.CultureInfo]::InvariantCulture)
    }
    $volume.Add($volVal)
  }

  if ($close.Count -eq 0) {
    throw "stooq returned no daily rows for $stooqSymbol"
  }

  $last = [double]$close[$close.Count - 1]
  $prev = if ($close.Count -gt 1) { [double]$close[$close.Count - 2] } else { $last }
  $currency = if ($Symbol.ToLowerInvariant().EndsWith(".t")) { "JPY" } else { "USD" }
  $payload = @{
    chart = @{
      result = @(
        @{
          meta = @{
            currency = $currency
            symbol = $Symbol
            exchangeName = "STOOQ"
            instrumentType = "EQUITY"
            regularMarketPrice = $last
            previousClose = $prev
            chartPreviousClose = $prev
            marketState = "CLOSED"
          }
          timestamp = $timestamps
          indicators = @{
            quote = @(
              @{
                open = $open
                high = $high
                low = $low
                close = $close
                volume = $volume
              }
            )
          }
        }
      )
      error = $null
    }
  }
  return ($payload | ConvertTo-Json -Depth 12 -Compress)
}

function ConvertTo-YahooChartFromYahooJapanHistory {
  param(
    [string]$Symbol,
    [string]$Range
  )

  if (-not $Symbol.ToLowerInvariant().EndsWith(".t")) {
    throw "Yahoo Japan history fallback supports Japanese .T symbols only"
  }

  $rows = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  $encodedSymbol = [System.Uri]::EscapeDataString($Symbol)
  for ($page = 1; $page -le 8; $page++) {
    $url = "https://finance.yahoo.co.jp/quote/$encodedSymbol/history"
    if ($page -gt 1) { $url = "$url?page=$page" }
    try {
      $html = Invoke-UpstreamText -Url $url -EncodingName "UTF-8"
    } catch {
      if ($page -eq 1) { throw }
      continue
    }

    $plain = $html -replace "<br\s*/?>", " "
    $plain = $plain -replace "<[^>]+>", " "
    $plain = [System.Net.WebUtility]::HtmlDecode($plain)
    $plain = ($plain -replace "\s+", " ").Trim()

    $pattern = "(\d{4})/(\d{1,2})/(\d{1,2})\s+([0-9,]+(?:\.[0-9]+)?)\s+([0-9,]+(?:\.[0-9]+)?)\s+([0-9,]+(?:\.[0-9]+)?)\s+([0-9,]+(?:\.[0-9]+)?)\s+([0-9,]+)\s+([0-9,]+(?:\.[0-9]+)?)"
    $matches = [regex]::Matches($plain, $pattern)
    foreach ($m in $matches) {
      $dateKey = "$($m.Groups[1].Value)-$($m.Groups[2].Value.PadLeft(2, '0'))-$($m.Groups[3].Value.PadLeft(2, '0'))"
      if ($seen.ContainsKey($dateKey)) { continue }
      $seen[$dateKey] = $true
      $rows.Add([ordered]@{
        date = $dateKey
        open = [double]::Parse($m.Groups[4].Value.Replace(",", ""), [Globalization.CultureInfo]::InvariantCulture)
        high = [double]::Parse($m.Groups[5].Value.Replace(",", ""), [Globalization.CultureInfo]::InvariantCulture)
        low = [double]::Parse($m.Groups[6].Value.Replace(",", ""), [Globalization.CultureInfo]::InvariantCulture)
        close = [double]::Parse($m.Groups[7].Value.Replace(",", ""), [Globalization.CultureInfo]::InvariantCulture)
        volume = [int64]::Parse($m.Groups[8].Value.Replace(",", ""), [Globalization.CultureInfo]::InvariantCulture)
        adjClose = [double]::Parse($m.Groups[9].Value.Replace(",", ""), [Globalization.CultureInfo]::InvariantCulture)
      })
    }
  }

  if ($rows.Count -eq 0) {
    throw "Yahoo Japan history returned no rows for $Symbol"
  }

  $orderedRows = $rows | Sort-Object date
  $timestamps = New-Object System.Collections.Generic.List[int64]
  $open = New-Object System.Collections.Generic.List[object]
  $high = New-Object System.Collections.Generic.List[object]
  $low = New-Object System.Collections.Generic.List[object]
  $close = New-Object System.Collections.Generic.List[object]
  $volume = New-Object System.Collections.Generic.List[object]

  foreach ($row in $orderedRows) {
    $dt = [DateTime]::ParseExact($row.date, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
    $dto = [DateTimeOffset]::new($dt.Year, $dt.Month, $dt.Day, 0, 0, 0, [TimeSpan]::Zero)
    $timestamps.Add($dto.ToUnixTimeSeconds())
    $open.Add($row.open)
    $high.Add($row.high)
    $low.Add($row.low)
    $close.Add($row.close)
    $volume.Add($row.volume)
  }

  $last = [double]$close[$close.Count - 1]
  $prev = if ($close.Count -gt 1) { [double]$close[$close.Count - 2] } else { $last }
  $payload = @{
    chart = @{
      result = @(
        @{
          meta = @{
            currency = "JPY"
            symbol = $Symbol
            exchangeName = "YAHOO_JP_HISTORY"
            instrumentType = "EQUITY"
            regularMarketPrice = $last
            previousClose = $prev
            chartPreviousClose = $prev
            marketState = "CLOSED"
          }
          timestamp = $timestamps
          indicators = @{
            quote = @(
              @{
                open = $open
                high = $high
                low = $low
                close = $close
                volume = $volume
              }
            )
          }
        }
      )
      error = $null
    }
  }
  return ($payload | ConvertTo-Json -Depth 12 -Compress)
}

function Get-CompanyName {
  param(
    [string]$Code,
    [string]$Market
  )

  $safeMarket = $Market.ToUpperInvariant()
  if ($safeMarket -eq "JP") {
    if ($Code -notmatch "^\d{4}$") { throw "invalid Japanese stock code" }
    $symbol = "$Code.T"
    try {
      $fallbackJson = ConvertTo-YahooQuoteFromYahooJapan -Symbols $symbol
      $fallback = $fallbackJson | ConvertFrom-Json
      $fallbackQuote = @($fallback.quoteResponse.result) | Select-Object -First 1
      if ($fallbackQuote -and ($fallbackQuote.longName -or $fallbackQuote.shortName)) {
        $fallbackName = [string]$fallbackQuote.longName
        if ([string]::IsNullOrWhiteSpace($fallbackName)) { $fallbackName = [string]$fallbackQuote.shortName }
        if ($fallbackName -and $fallbackName -ne $Code -and $fallbackName -ne $symbol -and $fallbackName.Length -le 80) {
          return $fallbackName
        }
      }
    } catch {}

    $url = "https://finance.yahoo.co.jp/quote/$Code.T"
    $html = Invoke-UpstreamText -Url $url -EncodingName "UTF-8"
    $rawPatterns = @(
      "<title>\s*([^\r\n<]{1,100}?)\s*(?:\u3010|\u3016)\s*$Code(?:\.T)?\s*(?:\u3011|\u3017)",
      ">\s*([^\s<>]{1,80})\s*(?:\u3010|\u3016)\s*$Code(?:\.T)?\s*(?:\u3011|\u3017)\s*<",
      """name""\s*:\s*""([^""]{1,80})"""
    )
    foreach ($pattern in $rawPatterns) {
      $m = [regex]::Match($html, $pattern)
      if ($m.Success) {
        $name = ConvertFrom-CellHtml $m.Groups[1].Value
        $colon = [char]0xFF1A
        if ($name.Contains($colon)) { $name = $name.Split($colon)[0].Trim() }
        if ($name -and $name.Length -le 80 -and $name -notmatch "Yahoo|JAPAN|finance") {
          return $name
        }
      }
    }

    $plain = $html -replace "<br\s*/?>", " "
    $plain = $plain -replace "<[^>]+>", " "
    $plain = [System.Net.WebUtility]::HtmlDecode($plain)
    $plain = ($plain -replace "\s+", " ").Trim()

    $patterns = @(
      "([^\s]{1,80})\s*(?:\u3010|\u3016)\s*$Code(?:\.T)?\s*(?:\u3011|\u3017)",
      "([^\s]{1,80})\s+$Code(?:\s|$)"
    )
    foreach ($pattern in $patterns) {
      $m = [regex]::Match($plain, $pattern)
      if ($m.Success) {
        $name = ($m.Groups[1].Value -replace "\s+", " ").Trim()
        if ($name -and $name.Length -le 80) {
          return $name
        }
      }
    }
    throw "company name not found"
  }

  if ($Code -notmatch "^[A-Za-z0-9\.\-\^=]{1,32}$") { throw "invalid ticker" }
  $encoded = [System.Uri]::EscapeDataString($Code)
  $urls = @(
    "https://query2.finance.yahoo.com/v7/finance/quote?symbols=$encoded",
    "https://query1.finance.yahoo.com/v7/finance/quote?symbols=$encoded"
  )
  $json = Invoke-UpstreamJsonAny $urls
  $data = $json | ConvertFrom-Json
  $q = $data.quoteResponse.result | Select-Object -First 1
  if ($q -and ($q.longName -or $q.shortName)) {
    if ($q.longName) { return [string]$q.longName }
    return [string]$q.shortName
  }
  throw "company name not found"
}

function ConvertFrom-CellHtml {
  param([string]$Html)

  if ([string]::IsNullOrWhiteSpace($Html)) { return "" }
  $text = $Html -replace "<br\s*/?>", " "
  $text = $text -replace "<[^>]+>", " "
  $text = [System.Net.WebUtility]::HtmlDecode($text)
  return ($text -replace "\s+", " ").Trim()
}

function ConvertFrom-PageHtml {
  param([string]$Html)

  if ([string]::IsNullOrWhiteSpace($Html)) { return "" }
  $text = $Html -replace "<br\s*/?>", " "
  $text = $text -replace "<[^>]+>", " "
  $text = [System.Net.WebUtility]::HtmlDecode($text)
  return ($text -replace "\s+", " ").Trim()
}

function ConvertTo-NullableDouble {
  param([string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $clean = $Text.Replace(",", "").Replace("%", "").Trim()
  if ([string]::IsNullOrWhiteSpace($clean) -or $clean -match "^-+$") { return $null }
  $value = 0.0
  if ([double]::TryParse($clean, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$value)) {
    return $value
  }
  return $null
}

function Get-YahooJapanMetric {
  param(
    [string]$PlainText,
    [string]$Label,
    [string]$UnitPattern = ""
  )

  $escapedLabel = [regex]::Escape($Label)
  $pattern = $escapedLabel + ".{0,120}?([0-9,]+(?:\.[0-9]+)?)"
  if (-not [string]::IsNullOrWhiteSpace($UnitPattern)) {
    $pattern = $pattern + "\s*" + $UnitPattern
  }
  $m = [regex]::Match($PlainText, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if (-not $m.Success) { return $null }
  return ConvertTo-NullableDouble $m.Groups[1].Value
}

function Get-YahooJapanCurrentPrice {
  param(
    [string]$PlainText,
    [string]$Code
  )

  $labelChange = "$([char]0x524D)$([char]0x65E5)$([char]0x6BD4)"
  $pattern = [regex]::Escape($Code) + "\s+.{0,80}?([0-9,]+(?:\.[0-9]+)?)\s+" + [regex]::Escape($labelChange)
  $m = [regex]::Match($PlainText, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if (-not $m.Success) { return $null }
  return ConvertTo-NullableDouble $m.Groups[1].Value
}

function Get-YahooJapanEarningsDate {
  param([string]$PlainText)

  if ([string]::IsNullOrWhiteSpace($PlainText)) { return $null }
  $label = "$([char]0x6C7A)$([char]0x7B97)$([char]0x767A)$([char]0x8868)$([char]0x4E88)$([char]0x5B9A)$([char]0x65E5)"
  $labelNext = "$([char]0x6B21)$([char]0x56DE)$([char]0x306E)$([char]0x6C7A)$([char]0x7B97)$([char]0x767A)$([char]0x8868)$([char]0x65E5)$([char]0x306F)"
  $patterns = @(
    [regex]::Escape($label) + "\s*[：:]\s*(\d{4})/(\d{1,2})/(\d{1,2})",
    [regex]::Escape($labelNext) + "\s*(\d{4})$([char]0x5E74)\s*(\d{1,2})$([char]0x6708)\s*(\d{1,2})$([char]0x65E5)",
    "$([char]0x6B21)$([char]0x56DE)$([char]0x306E)?\s*" + [regex]::Escape($label) + ".{0,80}?(\d{4})$([char]0x5E74)\s*(\d{1,2})$([char]0x6708)\s*(\d{1,2})$([char]0x65E5)"
  )
  foreach ($pattern in $patterns) {
    $m = [regex]::Match($PlainText, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
    if ($m.Success) {
      $year = [int]$m.Groups[1].Value
      $month = [int]$m.Groups[2].Value
      $day = [int]$m.Groups[3].Value
      try {
        return (Get-Date -Year $year -Month $month -Day $day).ToString("yyyy-MM-dd")
      } catch {
        return $null
      }
    }
  }
  return $null
}

function ConvertTo-YahooQuoteFromYahooJapan {
  param([string]$Symbols)

  $results = New-Object System.Collections.Generic.List[object]
  foreach ($rawSymbol in $Symbols.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries)) {
    $symbol = $rawSymbol.Trim().ToUpperInvariant()
    if ($symbol -notmatch "^\d{4}\.T$") {
      throw "Yahoo Japan quote fallback supports Japanese .T symbols only"
    }

    $code = $symbol.Substring(0, 4)
    $encodedSymbol = [System.Uri]::EscapeDataString($symbol)
    $url = "https://finance.yahoo.co.jp/quote/$encodedSymbol"
    $html = Invoke-UpstreamText -Url $url -EncodingName "UTF-8"
    $plain = ConvertFrom-PageHtml $html

    $name = $code
    $titlePattern = "<title>\s*([^\r\n<]{1,100}?)\s*(?:\u3010|\u3016)\s*$code(?:\.T)?\s*(?:\u3011|\u3017)"
    $titleMatch = [regex]::Match($html, $titlePattern)
    if ($titleMatch.Success) {
      $name = ConvertFrom-CellHtml $titleMatch.Groups[1].Value
    }

    $unitTimes = "$([char]0x500D)"
    $labelDividendYield = "$([char]0x914D)$([char]0x5F53)$([char]0x5229)$([char]0x56DE)$([char]0x308A)"
    $labelMarketCap = "$([char]0x6642)$([char]0x4FA1)$([char]0x7DCF)$([char]0x984D)"
    $labelPrevClose = "$([char]0x524D)$([char]0x65E5)$([char]0x7D42)$([char]0x5024)"
    $unitMillionYen = "$([char]0x767E)$([char]0x4E07)$([char]0x5186)"

    $per = Get-YahooJapanMetric -PlainText $plain -Label "PER" -UnitPattern $unitTimes
    $pbr = Get-YahooJapanMetric -PlainText $plain -Label "PBR" -UnitPattern $unitTimes
    $eps = Get-YahooJapanMetric -PlainText $plain -Label "EPS"
    $dividendYield = Get-YahooJapanMetric -PlainText $plain -Label $labelDividendYield -UnitPattern "%"
    $marketCapMillionYen = Get-YahooJapanMetric -PlainText $plain -Label $labelMarketCap -UnitPattern $unitMillionYen
    $prevClose = Get-YahooJapanMetric -PlainText $plain -Label $labelPrevClose

    $price = Get-YahooJapanCurrentPrice -PlainText $plain -Code $code
    $earningsDate = Get-YahooJapanEarningsDate -PlainText $plain
    if ($price -eq $null -and $per -ne $null -and $eps -ne $null -and $per -gt 0 -and $eps -gt 0) {
      $price = [Math]::Round($per * $eps, 2)
    }

    $marketCap = $null
    if ($marketCapMillionYen -ne $null) {
      $marketCap = [Math]::Round($marketCapMillionYen * 1000000, 0)
    }

    $results.Add([ordered]@{
      symbol = $symbol
      shortName = $name
      longName = $name
      currency = "JPY"
      quoteType = "EQUITY"
      marketState = "CLOSED"
      regularMarketPrice = $price
      regularMarketPreviousClose = $prevClose
      previousClose = $prevClose
      forwardPE = $per
      trailingPE = $per
      priceToBook = $pbr
      epsForward = $eps
      epsTrailingTwelveMonths = $eps
      marketCap = $marketCap
      dividendYield = $dividendYield
      earningsDate = $earningsDate
      earningsDateSource = "YAHOO_JAPAN_PAGE"
      source = "YAHOO_JAPAN_PAGE"
    })
  }

  $payload = @{
    quoteResponse = @{
      result = $results
      error = $null
    }
  }
  return ($payload | ConvertTo-Json -Depth 12 -Compress)
}

function Test-AllJapaneseYahooSymbols {
  param([string]$Symbols)

  $items = $Symbols.Split(",", [System.StringSplitOptions]::RemoveEmptyEntries)
  if ($items.Count -eq 0) { return $false }
  foreach ($rawSymbol in $items) {
    $symbol = $rawSymbol.Trim().ToUpperInvariant()
    if ($symbol -notmatch "^\d{4}\.T$") { return $false }
  }
  return $true
}

function Get-ObjectPropertyValue {
  param(
    [object]$Object,
    [string]$Name
  )

  if ($null -eq $Object) { return $null }
  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) { return $null }
  return $prop.Value
}

function Set-ObjectPropertyValue {
  param(
    [object]$Object,
    [string]$Name,
    [object]$Value
  )

  $prop = $Object.PSObject.Properties[$Name]
  if ($null -eq $prop) {
    Add-Member -InputObject $Object -NotePropertyName $Name -NotePropertyValue $Value
  } else {
    $prop.Value = $Value
  }
}

function Add-YahooJapanEarningsFallback {
  param(
    [string]$PrimaryJson,
    [string]$Symbols
  )

  if (-not (Test-AllJapaneseYahooSymbols $Symbols)) { return $PrimaryJson }

  try {
    $primary = $PrimaryJson | ConvertFrom-Json
  } catch {
    return $PrimaryJson
  }

  $primaryResults = @($primary.quoteResponse.result)
  if ($primaryResults.Count -eq 0) {
    try {
      return ConvertTo-YahooQuoteFromYahooJapan -Symbols $Symbols
    } catch {
      return $PrimaryJson
    }
  }

  $needsFallback = $false
  foreach ($quote in $primaryResults) {
    $dateValue = Get-ObjectPropertyValue -Object $quote -Name "earningsDate"
    if ([string]::IsNullOrWhiteSpace([string]$dateValue)) {
      $needsFallback = $true
      break
    }
  }
  if (-not $needsFallback) { return $PrimaryJson }

  try {
    $fallbackJson = ConvertTo-YahooQuoteFromYahooJapan -Symbols $Symbols
    $fallback = $fallbackJson | ConvertFrom-Json
  } catch {
    return $PrimaryJson
  }

  $fallbackBySymbol = @{}
  foreach ($fallbackQuote in @($fallback.quoteResponse.result)) {
    $fallbackSymbol = Get-ObjectPropertyValue -Object $fallbackQuote -Name "symbol"
    if ($fallbackSymbol) { $fallbackBySymbol[[string]$fallbackSymbol] = $fallbackQuote }
  }

  foreach ($quote in $primaryResults) {
    $symbol = Get-ObjectPropertyValue -Object $quote -Name "symbol"
    if (-not $symbol -or -not $fallbackBySymbol.ContainsKey([string]$symbol)) { continue }

    $currentDate = Get-ObjectPropertyValue -Object $quote -Name "earningsDate"
    if (-not [string]::IsNullOrWhiteSpace([string]$currentDate)) { continue }

    $fallbackQuote = $fallbackBySymbol[[string]$symbol]
    $fallbackDate = Get-ObjectPropertyValue -Object $fallbackQuote -Name "earningsDate"
    if ([string]::IsNullOrWhiteSpace([string]$fallbackDate)) { continue }

    Set-ObjectPropertyValue -Object $quote -Name "earningsDate" -Value $fallbackDate
    Set-ObjectPropertyValue -Object $quote -Name "earningsDateSource" -Value (Get-ObjectPropertyValue -Object $fallbackQuote -Name "earningsDateSource")
  }

  return ($primary | ConvertTo-Json -Depth 12 -Compress)
}

function ConvertTo-JpxDateString {
  param([string]$Value)

  $text = ([System.Net.WebUtility]::HtmlDecode([string]$Value) -replace "\s+", " ").Trim()
  if ([string]::IsNullOrWhiteSpace($text)) { return $null }

  $m = [regex]::Match($text, "(\d{4})\s*[/-]\s*(\d{1,2})\s*[/-]\s*(\d{1,2})")
  if (-not $m.Success) {
    $m = [regex]::Match($text, "(\d{4})年\s*(\d{1,2})月\s*(\d{1,2})日")
  }
  if (-not $m.Success -and $text -match "^\d{8}$") {
    $m = [regex]::Match($text, "^(\d{4})(\d{2})(\d{2})$")
  }
  if ($m.Success) {
    try {
      $dt = Get-Date -Year ([int]$m.Groups[1].Value) -Month ([int]$m.Groups[2].Value) -Day ([int]$m.Groups[3].Value)
      return $dt.ToString("yyyy-MM-dd")
    } catch {
      return $null
    }
  }

  if ($text -match "^\d{5}(?:\.\d+)?$") {
    try {
      $serial = [double]::Parse($text, [Globalization.CultureInfo]::InvariantCulture)
      if ($serial -ge 30000 -and $serial -le 80000) {
        return ([DateTime]"1899-12-30").AddDays($serial).ToString("yyyy-MM-dd")
      }
    } catch {}
  }
  return $null
}

function Get-JpxScheduledDateFromContext {
  param([string]$Text)

  $clean = ([System.Net.WebUtility]::HtmlDecode([string]$Text) -replace "\s+", " ").Trim()
  if ($clean -notmatch "開示予定|発表予定|Scheduled to be disclosed|Scheduled") { return $null }
  return ConvertTo-JpxDateString $clean
}

function Test-JpxEarningsExcelUrl {
  param([string]$Url)

  try {
    $uri = [System.Uri]::new($Url)
    return (
      $uri.Scheme -eq "https" -and
      $uri.Host -eq "www.jpx.co.jp" -and
      $uri.AbsolutePath.StartsWith("/listing/event-schedules/financial-announcement/") -and
      $uri.AbsolutePath.ToLowerInvariant().EndsWith(".xlsx")
    )
  } catch {
    return $false
  }
}

function Resolve-JpxUrl {
  param([string]$Href)

  $decoded = [System.Net.WebUtility]::HtmlDecode([string]$Href)
  $base = [System.Uri]::new($JpxEarningsPageUrl)
  return ([System.Uri]::new($base, $decoded)).AbsoluteUri
}

function Get-JpxEarningsExcelLinks {
  $html = Invoke-UpstreamText -Url $JpxEarningsPageUrl -EncodingName "UTF-8"
  $links = New-Object System.Collections.Generic.List[object]
  $seen = @{}
  $matches = [regex]::Matches($html, "href\s*=\s*[""']([^""']+\.xlsx(?:\?[^""']*)?)[""']", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)

  foreach ($m in $matches) {
    $url = Resolve-JpxUrl $m.Groups[1].Value
    if (-not (Test-JpxEarningsExcelUrl $url)) { continue }
    if ($seen.ContainsKey($url)) { continue }
    $seen[$url] = $true

    $start = [Math]::Max(0, $m.Index - 500)
    $contextHtml = $html.Substring($start, $m.Index - $start)
    $context = ConvertFrom-PageHtml $contextHtml
    $defaultDate = Get-JpxScheduledDateFromContext $context
    if ($context.Length -gt 220) { $context = $context.Substring($context.Length - 220) }

    $links.Add([pscustomobject][ordered]@{
      url = $url
      defaultDate = $defaultDate
      label = $context
    })
    if ($links.Count -ge 8) { break }
  }
  return $links
}

function Read-ZipEntryText {
  param(
    [System.IO.Compression.ZipArchive]$Archive,
    [string]$Name
  )

  $entry = $Archive.GetEntry($Name)
  if ($null -eq $entry) { return $null }
  $stream = $entry.Open()
  try {
    $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
  } finally {
    $stream.Dispose()
  }
}

function ConvertFrom-XlsxXmlText {
  param([string]$Value)
  return ([System.Net.WebUtility]::HtmlDecode([string]$Value) -replace "\s+", " ").Trim()
}

function Get-XlsxXmlAttribute {
  param(
    [string]$Attributes,
    [string]$Name
  )

  $m = [regex]::Match($Attributes, "\b$Name\s*=\s*[""']([^""']*)[""']")
  if ($m.Success) { return $m.Groups[1].Value }
  return $null
}

function Get-XlsxSharedStrings {
  param([System.IO.Compression.ZipArchive]$Archive)

  $strings = New-Object System.Collections.Generic.List[string]
  $xml = Read-ZipEntryText -Archive $Archive -Name "xl/sharedStrings.xml"
  if ([string]::IsNullOrWhiteSpace($xml)) { return $strings }

  foreach ($si in [regex]::Matches($xml, "<si\b[^>]*>(.*?)</si>", [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($t in [regex]::Matches($si.Groups[1].Value, "<t\b[^>]*>(.*?)</t>", [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
      $parts.Add((ConvertFrom-XlsxXmlText $t.Groups[1].Value))
    }
    $strings.Add(($parts -join ""))
  }
  return $strings
}

function ConvertFrom-XlsxColumnName {
  param([string]$Name)

  $value = 0
  foreach ($ch in $Name.ToUpperInvariant().ToCharArray()) {
    if ($ch -lt 'A' -or $ch -gt 'Z') { continue }
    $value = ($value * 26) + ([int][char]$ch - [int][char]'A' + 1)
  }
  return $value
}

function Get-XlsxCellValue {
  param(
    [string]$Attributes,
    [string]$InnerXml,
    [System.Collections.Generic.List[string]]$SharedStrings
  )

  $type = Get-XlsxXmlAttribute -Attributes $Attributes -Name "t"
  if ($type -eq "inlineStr") {
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($t in [regex]::Matches($InnerXml, "<t\b[^>]*>(.*?)</t>", [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
      $parts.Add((ConvertFrom-XlsxXmlText $t.Groups[1].Value))
    }
    return ($parts -join "")
  }

  $m = [regex]::Match($InnerXml, "<v[^>]*>(.*?)</v>", [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if (-not $m.Success) { return "" }
  $raw = ConvertFrom-XlsxXmlText $m.Groups[1].Value
  if ($type -eq "s") {
    try {
      $idx = [int]$raw
      if ($idx -ge 0 -and $idx -lt $SharedStrings.Count) { return $SharedStrings[$idx] }
    } catch {}
  }
  return $raw
}

function ConvertFrom-XlsxWorksheetXml {
  param(
    [string]$Xml,
    [System.Collections.Generic.List[string]]$SharedStrings,
    [string]$SheetName,
    [string]$SourceUrl,
    [string]$DefaultDate
  )

  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($row in [regex]::Matches($Xml, "<row\b([^>]*)>(.*?)</row>", [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
    $rowNumber = Get-XlsxXmlAttribute -Attributes $row.Groups[1].Value -Name "r"
    $values = @{}
    $nextColumn = 1
    foreach ($cell in [regex]::Matches($row.Groups[2].Value, "<c\b([^>]*)>(.*?)</c>", [System.Text.RegularExpressions.RegexOptions]::Singleline)) {
      $ref = Get-XlsxXmlAttribute -Attributes $cell.Groups[1].Value -Name "r"
      $column = $nextColumn
      if ($ref -match "^([A-Z]+)\d+$") {
        $column = ConvertFrom-XlsxColumnName $Matches[1]
      }
      $nextColumn = $column + 1
      $value = Get-XlsxCellValue -Attributes $cell.Groups[1].Value -InnerXml $cell.Groups[2].Value -SharedStrings $SharedStrings
      if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
        $values[$column] = [string]$value
      }
    }
    if ($values.Count -gt 0) {
      $rows.Add([pscustomobject][ordered]@{
        sourceUrl = $SourceUrl
        sourceDefaultDate = $DefaultDate
        sheet = $SheetName
        rowNumber = $rowNumber
        values = $values
      })
    }
  }
  return $rows
}

function ConvertFrom-JpxEarningsXlsxBytes {
  param(
    [byte[]]$Bytes,
    [string]$SourceUrl,
    [string]$DefaultDate
  )

  if ($Bytes.Length -gt $JpxEarningsMaxBytes) {
    throw "JPX earnings xlsx too large: $($Bytes.Length) bytes"
  }

  $rows = New-Object System.Collections.Generic.List[object]
  $ms = [System.IO.MemoryStream]::new($Bytes)
  $archive = $null
  try {
    $archive = [System.IO.Compression.ZipArchive]::new($ms, [System.IO.Compression.ZipArchiveMode]::Read)
    $sharedStrings = Get-XlsxSharedStrings $archive
    $sheetEntries = @($archive.Entries | Where-Object { $_.FullName -match "^xl/worksheets/sheet\d+\.xml$" } | Sort-Object FullName)
    foreach ($entry in $sheetEntries) {
      $stream = $entry.Open()
      try {
        $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8)
        try { $xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
      } finally {
        $stream.Dispose()
      }
      foreach ($row in (ConvertFrom-XlsxWorksheetXml -Xml $xml -SharedStrings $sharedStrings -SheetName $entry.FullName -SourceUrl $SourceUrl -DefaultDate $DefaultDate)) {
        $rows.Add($row)
      }
    }
  } finally {
    if ($archive) { $archive.Dispose() }
    $ms.Dispose()
  }
  return $rows
}

function Get-JpxEarningsDataset {
  $todayKey = (Get-Date).ToString("yyyy-MM-dd")
  if ($script:JpxEarningsCache -and $script:JpxEarningsCache.cacheDate -eq $todayKey) {
    return $script:JpxEarningsCache
  }

  $links = @(Get-JpxEarningsExcelLinks)
  $rows = New-Object System.Collections.Generic.List[object]
  $errors = New-Object System.Collections.Generic.List[string]

  foreach ($link in $links) {
    try {
      $bytes = Invoke-UpstreamBytes -Url $link.url
      if ($bytes.Length -gt $JpxEarningsMaxBytes) {
        throw "JPX earnings xlsx too large: $($bytes.Length) bytes"
      }
      foreach ($row in (ConvertFrom-JpxEarningsXlsxBytes -Bytes $bytes -SourceUrl $link.url -DefaultDate $link.defaultDate)) {
        $rows.Add($row)
      }
    } catch {
      $errors.Add("$($link.url): $(Get-DeepErrorMessage $_)")
    }
  }

  $script:JpxEarningsCache = [pscustomobject][ordered]@{
    cacheDate = $todayKey
    fetchedAt = [DateTime]::Now.ToString("o")
    sourcePage = $JpxEarningsPageUrl
    links = $links
    rows = $rows
    errors = $errors
  }
  return $script:JpxEarningsCache
}

function Test-JpxCodeCell {
  param(
    [string]$Value,
    [string]$Code
  )

  $clean = ([string]$Value).Trim()
  if ($clean -eq $Code) { return $true }
  if (($clean -replace "[^\d]", "") -eq $Code -and $clean -match "^\s*$Code\s*$") { return $true }
  return $false
}

function Get-JpxRowText {
  param([hashtable]$Values)

  $parts = New-Object System.Collections.Generic.List[string]
  foreach ($key in ($Values.Keys | Sort-Object {[int]$_})) {
    $value = ([string]$Values[$key] -replace "\s+", " ").Trim()
    if ($value) { $parts.Add($value) }
  }
  $text = ($parts -join " / ")
  if ($text.Length -gt 360) { return $text.Substring(0, 360) }
  return $text
}

function Get-JpxCompanyNameFromRow {
  param(
    [hashtable]$Values,
    [string]$Code
  )

  foreach ($key in ($Values.Keys | Sort-Object {[int]$_})) {
    $value = ([string]$Values[$key] -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { continue }
    if (Test-JpxCodeCell -Value $value -Code $Code) { continue }
    if (ConvertTo-JpxDateString $value) { continue }
    if ($value -match "コード|Code|市場|Market|予定|発表|決算|期末|四半期|Fiscal|Schedule|Date") { continue }
    if ($value.Length -le 80) { return $value }
  }
  return ""
}

function Get-JpxRowMapKey {
  param([object]$Row)
  return "$($Row.sourceUrl)|$($Row.sheet)"
}

function Get-JpxHeaderMaps {
  param([object]$Rows)

  $maps = @{}
  foreach ($row in $Rows) {
    $values = $row.PSObject.Properties["values"].Value
    if ($null -eq $values) { continue }

    $scheduleCol = $null
    $codeCol = $null
    $companyCol = $null
    foreach ($key in $values.Keys) {
      $value = ([string]$values[$key] -replace "\s+", " ").Trim()
      if ($value -match "決算発表予定日|Scheduled Dates? for Earnings Announcements") { $scheduleCol = [int]$key }
      elseif ($value -match "コード|^Code$") { $codeCol = [int]$key }
      elseif ($value -match "会社名|Issue Name" -and $null -eq $companyCol) { $companyCol = [int]$key }
    }

    if ($scheduleCol -ne $null -and $codeCol -ne $null) {
      $maps[(Get-JpxRowMapKey -Row $row)] = [pscustomobject][ordered]@{
        scheduleCol = $scheduleCol
        codeCol = $codeCol
        companyCol = $companyCol
      }
    }
  }
  return $maps
}

function Find-JpxEarningsForCode {
  param([string]$Code)

  $dataset = Get-JpxEarningsDataset
  $datasetRows = $dataset.PSObject.Properties["rows"].Value
  $datasetLinks = $dataset.PSObject.Properties["links"].Value
  $datasetErrors = $dataset.PSObject.Properties["errors"].Value
  $headerMaps = Get-JpxHeaderMaps -Rows $datasetRows
  $today = (Get-Date).Date
  $upcoming = New-Object System.Collections.Generic.List[object]
  $past = New-Object System.Collections.Generic.List[object]

  foreach ($row in $datasetRows) {
    $values = $row.PSObject.Properties["values"].Value
    $map = $headerMaps[(Get-JpxRowMapKey -Row $row)]
    $hasCode = $false
    if ($map -and $values.ContainsKey($map.codeCol)) {
      $hasCode = Test-JpxCodeCell -Value $values[$map.codeCol] -Code $Code
    } else {
      foreach ($key in $values.Keys) {
        if (Test-JpxCodeCell -Value $values[$key] -Code $Code) {
          $hasCode = $true
          break
        }
      }
    }
    if (-not $hasCode) { continue }

    $dateCandidates = New-Object System.Collections.Generic.List[string]
    if ($map -and $values.ContainsKey($map.scheduleCol)) {
      $scheduleDate = ConvertTo-JpxDateString $values[$map.scheduleCol]
      if ($scheduleDate) {
        $dateCandidates.Add($scheduleDate)
        $hasCode = $true
      }
    } elseif ($row.sourceDefaultDate) {
      $dateCandidates.Add([string]$row.sourceDefaultDate)
    }

    foreach ($dateText in ($dateCandidates | Select-Object -Unique)) {
      try {
        $dt = [DateTime]::ParseExact($dateText, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
      } catch {
        continue
      }
      $entry = [pscustomobject][ordered]@{
        date = $dateText
        companyName = Get-JpxCompanyNameFromRow -Values $values -Code $Code
        rowText = Get-JpxRowText -Values $values
        sourceUrl = $row.sourceUrl
        sourceDefaultDate = $row.sourceDefaultDate
        sheet = $row.sheet
        rowNumber = $row.rowNumber
      }
      if ($dt.Date -ge $today) { $upcoming.Add($entry) } else { $past.Add($entry) }
    }
  }

  $best = @($upcoming | Sort-Object date | Select-Object -First 1)
  $latestPast = @($past | Sort-Object date -Descending | Select-Object -First 1)
  return [pscustomobject][ordered]@{
    ok = $true
    code = $Code
    date = if ($best.Count) { $best[0].date } else { $null }
    dateSource = if ($best.Count) { "JPX_OFFICIAL_EXCEL" } else { $null }
    confidence = if ($best.Count) { "official" } else { "not_found" }
    companyName = if ($best.Count) { $best[0].companyName } else { "" }
    rowText = if ($best.Count) { $best[0].rowText } else { "" }
    sourceUrl = if ($best.Count) { $best[0].sourceUrl } else { $null }
    latestKnownDate = if ($latestPast.Count) { $latestPast[0].date } else { $null }
    latestKnownRowText = if ($latestPast.Count) { $latestPast[0].rowText } else { "" }
    fetchedAt = $dataset.fetchedAt
    cacheDate = $dataset.cacheDate
    sourcePage = $dataset.sourcePage
    sourceFileCount = $datasetLinks.Count
    parsedRowCount = $datasetRows.Count
    errors = $datasetErrors
  }
}

function Get-CellByClass {
  param(
    [string]$RowHtml,
    [string]$ClassName
  )

  $pattern = "<td[^>]*class\s*=\s*[""'][^""']*$ClassName[^""']*[""'][^>]*>(.*?)</td>"
  $m = [regex]::Match($RowHtml, $pattern, [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if ($m.Success) { return ConvertFrom-CellHtml $m.Groups[1].Value }
  return ""
}

function Get-FirstHref {
  param([string]$RowHtml)

  $m = [regex]::Match($RowHtml, "<a[^>]+href\s*=\s*[""']([^""']+)[""']", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if (-not $m.Success) { return $null }
  $href = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
  if ($href -match "^https?://") { return $href }
  $clean = $href.Trim()
  if ($clean.StartsWith("./")) { $clean = $clean.Substring(2) }
  return "https://www.release.tdnet.info/inbs/$clean"
}

function Get-TdnetCategory {
  param([string]$Title)
  if ($Title -match "KPI") { return "kpi" }
  return "other"
}

function Get-TdnetItems {
  param(
    [string]$Code,
    [int]$Days
  )

  $items = New-Object System.Collections.Generic.List[object]
  $today = (Get-Date).Date
  $safeDays = [Math]::Min([Math]::Max($Days, 1), 31)

  for ($i = 0; $i -lt $safeDays; $i++) {
    $date = $today.AddDays(-$i)
    $dateKey = $date.ToString("yyyyMMdd")
    $url = "https://www.release.tdnet.info/inbs/I_list_001_$dateKey.html"
    try {
      $html = Invoke-UpstreamText -Url $url -EncodingName "Shift_JIS"
    } catch {
      continue
    }

    $rows = [regex]::Matches($html, "<tr[^>]*>.*?</tr>", [System.Text.RegularExpressions.RegexOptions]::Singleline)
    foreach ($rowMatch in $rows) {
      $row = $rowMatch.Value
      $rowCode = Get-CellByClass $row "kjCode"
      if ([string]::IsNullOrWhiteSpace($rowCode)) { continue }
      if ($rowCode -notmatch "^$([regex]::Escape($Code))") { continue }

      $title = Get-CellByClass $row "kjTitle"
      if ([string]::IsNullOrWhiteSpace($title)) { continue }

      $time = Get-CellByClass $row "kjTime"
      $name = Get-CellByClass $row "kjName"
      $exchange = Get-CellByClass $row "kjPlace"
      $pdfUrl = Get-FirstHref $row
      $category = Get-TdnetCategory $title

      $items.Add([ordered]@{
        id       = "$dateKey-$time-$rowCode-$title"
        date     = $date.ToString("yyyy-MM-dd")
        time     = $time
        code     = $rowCode
        name     = $name
        exchange = $exchange
        title    = $title
        category = $category
        url      = $pdfUrl
      })
    }
  }

  return $items
}

function Convert-YahooDisclosureDate {
  param([string]$DateText)

  $parts = $DateText.Split("/")
  $today = (Get-Date).Date
  if ($parts.Length -eq 3) {
    return [DateTime]::new([int]$parts[0], [int]$parts[1], [int]$parts[2])
  }
  if ($parts.Length -eq 2) {
    $dt = [DateTime]::new($today.Year, [int]$parts[0], [int]$parts[1])
    if ($dt -gt $today.AddDays(7)) { $dt = $dt.AddYears(-1) }
    return $dt
  }
  throw "invalid disclosure date"
}

function Normalize-TimeText {
  param([string]$TimeText)

  if ([string]::IsNullOrWhiteSpace($TimeText)) { return "" }
  $parts = $TimeText.Split(":")
  if ($parts.Length -ne 2) { return $TimeText }
  return "$($parts[0].PadLeft(2, '0')):$($parts[1].PadLeft(2, '0'))"
}

function Get-YahooDisclosureItems {
  param(
    [string]$Code,
    [int]$Limit
  )

  $items = New-Object System.Collections.Generic.List[object]
  $url = "https://finance.yahoo.co.jp/quote/$Code.T/disclosure"
  $html = Invoke-UpstreamText -Url $url -EncodingName "UTF-8"
  $name = ""
  try { $name = Get-CompanyName -Code $Code -Market "JP" } catch {}

  $opts = [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  $anchors = [regex]::Matches($html, "<a[^>]+href\s*=\s*[""']([^""']+)[""'][^>]*>(.*?)</a>", $opts)
  $seen = @{}
  foreach ($a in $anchors) {
    $href = [System.Net.WebUtility]::HtmlDecode($a.Groups[1].Value)
    $text = ConvertFrom-CellHtml $a.Groups[2].Value
    if ($text -notmatch "TDnet\s+PDF") { continue }
    $m = [regex]::Match($text, "^(.*?)\s+((?:\d{4}/)?\d{1,2}/\d{1,2})(?:\s+(\d{1,2}:\d{1,2}))?\s+TDnet\s+PDF", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    if (-not $m.Success) { continue }

    $title = ($m.Groups[1].Value -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($title)) { continue }
    $dt = Convert-YahooDisclosureDate $m.Groups[2].Value
    $time = Normalize-TimeText $m.Groups[3].Value
    if ($href -notmatch "^https?://") {
      $href = "https://finance.yahoo.co.jp$href"
    }
    $id = "$($dt.ToString('yyyyMMdd'))-$time-$Code-$title"
    if ($seen.ContainsKey($id)) { continue }
    $seen[$id] = $true

    $items.Add([ordered]@{
      id       = $id
      date     = $dt.ToString("yyyy-MM-dd")
      time     = $time
      code     = $Code
      name     = $name
      exchange = "Yahoo Finance"
      title    = $title
      category = Get-TdnetCategory $title
      url      = $href
      source   = "YahooFinanceDisclosure"
    })

    if ($items.Count -ge $Limit) { break }
  }

  return $items
}

function Test-AllowedPdfUrl {
  param([string]$Url)

  if ([string]::IsNullOrWhiteSpace($Url)) { return $false }
  if ($Url.Length -gt 2048) { return $false }
  return (
    $Url -match "^https://finance-frontend-pc-dist\.west\.edge\.storage-yahoo\.jp/disclosure/\d{8}/[A-Za-z0-9]+\.pdf$" -or
    $Url -match "^https://www\.release\.tdnet\.info/inbs/[A-Za-z0-9_\-./]+\.pdf$"
  )
}

function Expand-FlateData {
  param(
    [byte[]]$Bytes,
    [int]$Offset,
    [int]$Length
  )

  $tries = @(
    @{ Skip = 0; Size = $Length },
    @{ Skip = 2; Size = [Math]::Max(0, $Length - 6) },
    @{ Skip = 2; Size = [Math]::Max(0, $Length - 2) }
  )

  foreach ($try in $tries) {
    if ($try.Size -le 0) { continue }
    try {
      $ms = [System.IO.MemoryStream]::new($Bytes, $Offset + $try.Skip, $try.Size)
      $ds = [System.IO.Compression.DeflateStream]::new($ms, [System.IO.Compression.CompressionMode]::Decompress)
      $out = [System.IO.MemoryStream]::new()
      $ds.CopyTo($out)
      $ds.Dispose()
      return $out.ToArray()
    } catch {}
  }
  return $null
}

function Convert-HexToUnicodeString {
  param([string]$Hex)

  if ([string]::IsNullOrWhiteSpace($Hex)) { return "" }
  $clean = $Hex -replace "[^0-9A-Fa-f]", ""
  $sb = [System.Text.StringBuilder]::new()
  for ($i = 0; $i + 3 -lt $clean.Length; $i += 4) {
    try {
      $cp = [Convert]::ToInt32($clean.Substring($i, 4), 16)
      if ($cp -le 0xFFFF) {
        [void]$sb.Append([char]$cp)
      } else {
        [void]$sb.Append([char]::ConvertFromUtf32($cp))
      }
    } catch {}
  }
  return $sb.ToString()
}

function Add-CMapMappings {
  param(
    [hashtable]$Map,
    [string]$Text
  )

  $opts = [System.Text.RegularExpressions.RegexOptions]::Singleline
  foreach ($block in [regex]::Matches($Text, "\d+\s+beginbfchar(.*?)endbfchar", $opts)) {
    foreach ($m in [regex]::Matches($block.Groups[1].Value, "<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>")) {
      $src = $m.Groups[1].Value.ToUpperInvariant().PadLeft(4, "0")
      $Map[$src] = Convert-HexToUnicodeString $m.Groups[2].Value
    }
  }

  foreach ($block in [regex]::Matches($Text, "\d+\s+beginbfrange(.*?)endbfrange", $opts)) {
    foreach ($m in [regex]::Matches($block.Groups[1].Value, "<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>")) {
      $start = [Convert]::ToInt32($m.Groups[1].Value, 16)
      $end = [Convert]::ToInt32($m.Groups[2].Value, 16)
      $dst = [Convert]::ToInt32($m.Groups[3].Value, 16)
      for ($code = $start; $code -le $end -and ($code - $start) -lt 2000; $code++) {
        $key = $code.ToString("X4")
        $cp = $dst + ($code - $start)
        if ($cp -le 0xFFFF) { $Map[$key] = [string][char]$cp }
        else { $Map[$key] = [char]::ConvertFromUtf32($cp) }
      }
    }
  }
}

function Convert-PdfHexText {
  param(
    [string]$Hex,
    [hashtable]$Map
  )

  $clean = $Hex -replace "[^0-9A-Fa-f]", ""
  $sb = [System.Text.StringBuilder]::new()
  for ($i = 0; $i + 3 -lt $clean.Length; $i += 4) {
    $key = $clean.Substring($i, 4).ToUpperInvariant()
    if ($Map.ContainsKey($key)) {
      [void]$sb.Append([string]$Map[$key])
    }
  }
  return $sb.ToString()
}

function ConvertFrom-PdfBytesToText {
  param([byte[]]$Bytes)

  if ($Bytes.Length -gt 10MB) { throw "PDF is too large" }
  $latin = [System.Text.Encoding]::GetEncoding("ISO-8859-1")
  $ascii = $latin.GetString($Bytes)
  $streams = New-Object System.Collections.Generic.List[string]
  $idx = 0

  while (($s = $ascii.IndexOf("stream", $idx)) -ge 0) {
    $dataStart = $s + 6
    if ($dataStart + 1 -lt $Bytes.Length -and $Bytes[$dataStart] -eq 13 -and $Bytes[$dataStart + 1] -eq 10) {
      $dataStart += 2
    } elseif ($dataStart -lt $Bytes.Length -and $Bytes[$dataStart] -eq 10) {
      $dataStart += 1
    }
    $end = $ascii.IndexOf("endstream", $dataStart)
    if ($end -lt 0) { break }
    $len = $end - $dataStart
    $dictStart = [Math]::Max(0, $s - 500)
    $dict = $ascii.Substring($dictStart, [Math]::Min(500, $s - $dictStart))
    if ($dict -match "FlateDecode" -and $len -gt 0) {
      $raw = Expand-FlateData -Bytes $Bytes -Offset $dataStart -Length $len
      if ($raw) { $streams.Add($latin.GetString($raw)) }
    }
    $idx = $end + 9
  }

  $map = @{}
  foreach ($stream in $streams) {
    if ($stream -match "beginbfchar|beginbfrange") { Add-CMapMappings -Map $map -Text $stream }
  }

  $sb = [System.Text.StringBuilder]::new()
  $opts = [System.Text.RegularExpressions.RegexOptions]::Singleline
  foreach ($stream in $streams) {
    if ($stream -notmatch "BT|Tj|TJ") { continue }
    foreach ($m in [regex]::Matches($stream, "<([0-9A-Fa-f]+)>\s*Tj")) {
      $piece = Convert-PdfHexText -Hex $m.Groups[1].Value -Map $map
      if ($piece) { [void]$sb.AppendLine($piece) }
    }
    foreach ($arr in [regex]::Matches($stream, "\[(.*?)\]\s*TJ", $opts)) {
      $pieceSb = [System.Text.StringBuilder]::new()
      foreach ($m in [regex]::Matches($arr.Groups[1].Value, "<([0-9A-Fa-f]+)>")) {
        [void]$pieceSb.Append((Convert-PdfHexText -Hex $m.Groups[1].Value -Map $map))
      }
      $piece = $pieceSb.ToString()
      if ($piece) { [void]$sb.AppendLine($piece) }
    }
  }

  $text = $sb.ToString()
  $text = [System.Text.RegularExpressions.Regex]::Replace($text, "\s+", " ").Trim()
  if ($text.Length -gt 120000) { $text = $text.Substring(0, 120000) }
  if ($text.Length -lt 50) { throw "PDF text extraction produced too little text" }
  return $text
}

function Find-HeaderEnd {
  param([byte[]]$Bytes)

  for ($i = 0; $i -le $Bytes.Length - 4; $i++) {
    if ($Bytes[$i] -eq 13 -and $Bytes[$i + 1] -eq 10 -and $Bytes[$i + 2] -eq 13 -and $Bytes[$i + 3] -eq 10) {
      return $i
    }
  }
  return -1
}

function Read-HttpRequest {
  param([System.Net.Sockets.TcpClient]$Client)

  $stream = $Client.GetStream()
  if ($stream.CanTimeout) {
    $stream.ReadTimeout = $ClientReadTimeoutMs
    $stream.WriteTimeout = $ClientWriteTimeoutMs
  }
  $buffer = New-Object byte[] 8192
  $memory = [System.IO.MemoryStream]::new()
  $headerEnd = -1

  while ($headerEnd -lt 0) {
    $read = $stream.Read($buffer, 0, $buffer.Length)
    if ($read -le 0) { break }
    $memory.Write($buffer, 0, $read)
    $headerEnd = Find-HeaderEnd -Bytes $memory.ToArray()
    if ($memory.Length -gt 262144) { throw "request headers too large" }
  }

  if ($headerEnd -lt 0) { throw "request headers incomplete" }

  $raw = $memory.ToArray()
  $headerText = [System.Text.Encoding]::ASCII.GetString($raw, 0, $headerEnd)
  $lines = $headerText -split "`r`n"
  if ($lines.Length -eq 0 -or [string]::IsNullOrWhiteSpace($lines[0])) {
    throw "bad request line"
  }

  $headers = @{}
  if ($lines.Length -gt 1) {
    foreach ($line in $lines[1..($lines.Length - 1)]) {
      if ([string]::IsNullOrWhiteSpace($line)) { continue }
      $idx = $line.IndexOf(":")
      if ($idx -lt 1) { continue }
      $key = $line.Substring(0, $idx).Trim().ToLowerInvariant()
      $value = $line.Substring($idx + 1).Trim()
      $headers[$key] = $value
    }
  }

  $contentLength = 0
  if ($headers.ContainsKey("content-length")) {
    [void][int]::TryParse($headers["content-length"], [ref]$contentLength)
  }
  if ($contentLength -lt 0 -or $contentLength -gt 1048576) {
    throw "invalid content length"
  }

  $bodyStart = $headerEnd + 4
  $bodyBytes = New-Object byte[] $contentLength
  $alreadyBuffered = [Math]::Max(0, $raw.Length - $bodyStart)
  if ($alreadyBuffered -gt 0) {
    [Array]::Copy($raw, $bodyStart, $bodyBytes, 0, [Math]::Min($alreadyBuffered, $contentLength))
  }

  $offset = [Math]::Min($alreadyBuffered, $contentLength)
  while ($offset -lt $contentLength) {
    $read = $stream.Read($bodyBytes, $offset, $contentLength - $offset)
    if ($read -le 0) { throw "request body incomplete" }
    $offset += $read
  }

  $requestLine = $lines[0]
  $parts = $requestLine.Split(" ")
  if ($parts.Length -lt 2) { throw "bad request" }

  return [ordered]@{
    Stream  = $stream
    Method  = $parts[0].ToUpperInvariant()
    Target  = $parts[1]
    Headers = $headers
    Body    = if ($contentLength -gt 0) { [System.Text.Encoding]::UTF8.GetString($bodyBytes) } else { "" }
  }
}

function Handle-Request {
  param(
    [string]$Method,
    [string]$Path,
    [hashtable]$Query,
    [string]$Body,
    [System.IO.Stream]$Stream
  )

  if ($Method -eq "OPTIONS") {
    Send-NoContent $Stream
    return
  }
  if ($Method -ne "GET") {
    Send-Json $Stream 405 @{ ok = $false; error = "method not allowed" }
    return
  }
  if ($Path -eq "/health") {
    Send-Json $Stream 200 @{ ok = $true; time = [DateTime]::Now.ToString("o"); port = $Port; version = $ProxyVersion }
    return
  }
  if ($Path -eq "/name") {
    $code = $Query["code"]
    $market = $Query["market"]; if ([string]::IsNullOrWhiteSpace($market)) { $market = "JP" }
    if ([string]::IsNullOrWhiteSpace($code)) {
      Send-Json $Stream 400 @{ ok = $false; error = "missing code" }
      return
    }
    if ($market.ToUpperInvariant() -eq "JP") {
      if ($code -notmatch "^\d{4}$") {
        Send-Json $Stream 400 @{ ok = $false; error = "invalid Japanese stock code" }
        return
      }
    } elseif ($code -notmatch "^[A-Za-z0-9\.\-\^=]{1,32}$") {
      Send-Json $Stream 400 @{ ok = $false; error = "invalid ticker" }
      return
    }
    $name = Get-CompanyName -Code $code -Market $market
    Send-Json $Stream 200 @{ ok = $true; code = $code; market = $market.ToUpperInvariant(); name = $name }
    return
  }
  if ($Path -eq "/jpx/earnings") {
    $code = $Query["code"]
    if ([string]::IsNullOrWhiteSpace($code) -or $code -notmatch "^\d{4}$") {
      Send-Json $Stream 400 @{ ok = $false; error = "code must be a 4 digit Japanese stock code" }
      return
    }
    try {
      Send-Json $Stream 200 (Find-JpxEarningsForCode -Code $code)
    } catch {
      Send-Json $Stream 502 @{ ok = $false; code = $code; error = "jpx earnings failed"; detail = (Get-DeepErrorMessage $_) }
    }
    return
  }
  if ($Path -eq "/yahoo/quote") {
    $symbol = $Query["symbol"]
    if ([string]::IsNullOrWhiteSpace($symbol)) {
      Send-Json $Stream 400 @{ ok = $false; error = "missing symbol" }
      return
    }
    if ($symbol.Length -gt 2048 -or $symbol -notmatch "^[A-Za-z0-9\.\-\^=,]+$") {
      Send-Json $Stream 400 @{ ok = $false; error = "invalid symbol" }
      return
    }
    $encoded = [System.Uri]::EscapeDataString($symbol)
    $urls = @(
      "https://query2.finance.yahoo.com/v7/finance/quote?symbols=$encoded",
      "https://query1.finance.yahoo.com/v7/finance/quote?symbols=$encoded"
    )
    try {
      $primaryJson = Invoke-UpstreamJsonAny $urls
      Send-Body $Stream 200 (Add-YahooJapanEarningsFallback -PrimaryJson $primaryJson -Symbols $symbol)
    } catch {
      Send-Body $Stream 200 (ConvertTo-YahooQuoteFromYahooJapan -Symbols $symbol)
    }
    return
  }
  if ($Path -eq "/yahoo/chart") {
    $symbol = $Query["symbol"]
    if ([string]::IsNullOrWhiteSpace($symbol)) {
      Send-Json $Stream 400 @{ ok = $false; error = "missing symbol" }
      return
    }
    if ($symbol.Length -gt 64 -or $symbol -notmatch "^[A-Za-z0-9\.\-\^=]+$") {
      Send-Json $Stream 400 @{ ok = $false; error = "invalid symbol" }
      return
    }
    $range = $Query["range"]; if ([string]::IsNullOrWhiteSpace($range)) { $range = "1y" }
    $interval = $Query["interval"]; if ([string]::IsNullOrWhiteSpace($interval)) { $interval = "1d" }
    if ($range -notmatch "^[0-9]+[dmy]$|^ytd$|^max$") { $range = "1y" }
    if ($interval -notmatch "^[0-9]+[mhdwk]$") { $interval = "1d" }
    $encoded = [System.Uri]::EscapeDataString($symbol)
    $urls = @(
      "https://query1.finance.yahoo.com/v8/finance/chart/$encoded?interval=$interval&range=$range",
      "https://query2.finance.yahoo.com/v8/finance/chart/$encoded?interval=$interval&range=$range"
    )
    try {
      Send-Body $Stream 200 (Invoke-UpstreamJsonAny $urls)
    } catch {
      try {
        Send-Body $Stream 200 (ConvertTo-YahooChartFromStooq -Symbol $symbol -Range $range)
      } catch {
        Send-Body $Stream 200 (ConvertTo-YahooChartFromYahooJapanHistory -Symbol $symbol -Range $range)
      }
    }
    return
  }
  if ($Path -eq "/tdnet/ir") {
    if ($Method -ne "GET") {
      Send-Json $Stream 405 @{ ok = $false; error = "method not allowed" }
      return
    }
    $code = $Query["code"]
    if ([string]::IsNullOrWhiteSpace($code) -or $code -notmatch "^\d{4}$") {
      Send-Json $Stream 400 @{ ok = $false; error = "code must be a 4 digit Japanese stock code" }
      return
    }
    $days = 31
    if ($Query["days"]) { [void][int]::TryParse($Query["days"], [ref]$days) }
    $safeDays = [Math]::Min([Math]::Max($days, 1), 31)
    $items = New-Object System.Collections.Generic.List[object]
    $seen = @{}
    foreach ($item in (Get-TdnetItems -Code $code -Days $safeDays)) {
      $items.Add($item)
      $seen[$item.id] = $true
    }
    try {
      $cutoff = (Get-Date).Date.AddDays(-1 * ($safeDays - 1))
      foreach ($item in (Get-YahooDisclosureItems -Code $code -Limit 80)) {
        $itemDate = [DateTime]::ParseExact($item.date, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture)
        if ($itemDate -lt $cutoff) { continue }
        if ($seen.ContainsKey($item.id)) { continue }
        $items.Add($item)
        $seen[$item.id] = $true
      }
    } catch {
      # TDnet official list remains the primary source; Yahoo disclosure is a best-effort fallback.
    }
    Send-Json $Stream 200 @{ ok = $true; source = "TDnet"; code = $code; days = $safeDays; fetchedAt = [DateTime]::Now.ToString("o"); count = $items.Count; items = $items }
    return
  }
  if ($Path -eq "/news/morning") {
    $codes = @(Split-ListQueryValue $Query["codes"])
    $terms = @(Split-ListQueryValue $Query["terms"])
    $largeCaps = @(Split-ListQueryValue $Query["largeCaps"])
    if ($codes.Count -gt 120) {
      Send-Json $Stream 400 @{ ok = $false; error = "too many codes" }
      return
    }
    foreach ($code in $codes) {
      if ($code -notmatch "^\d{4}$") {
        Send-Json $Stream 400 @{ ok = $false; error = "codes must be 4 digit Japanese stock codes" }
        return
      }
    }
    $days = 3
    if ($Query["days"]) { [void][int]::TryParse($Query["days"], [ref]$days) }
    $safeDays = [Math]::Min([Math]::Max($days, 1), 31)
    $xSignals = [string]$Query["xSignals"]
    if ($xSignals.Length -gt 200000) {
      Send-Json $Stream 400 @{ ok = $false; error = "xSignals is too large" }
      return
    }
    try {
      $summary = Get-MorningStockNewsSummary -Codes $codes -Days $safeDays -Terms $terms -XSignalsJson $xSignals -LargeCapCodes $largeCaps
      Send-Json $Stream 200 $summary
    } catch {
      Send-Json $Stream 502 @{ ok = $false; error = "morning news failed"; detail = (Get-DeepErrorMessage $_) }
    }
    return
  }
  if ($Path -eq "/ir/pdf-text") {
    $url = $Query["url"]
    if (-not (Test-AllowedPdfUrl -Url $url)) {
      Send-Json $Stream 400 @{ ok = $false; error = "invalid or unsupported PDF URL" }
      return
    }
    $bytes = Invoke-UpstreamBytes -Url $url
    $text = ConvertFrom-PdfBytesToText -Bytes $bytes
    Send-Json $Stream 200 @{
      ok = $true
      url = $url
      bytes = $bytes.Length
      textLength = $text.Length
      text = $text
      extractedAt = [DateTime]::Now.ToString("o")
    }
    return
  }
  Send-Json $Stream 400 @{ ok = $false; error = "unknown path" }
}

$listener = $null
try {
  $ip = [System.Net.IPAddress]::Parse("127.0.0.1")
  $listener = [System.Net.Sockets.TcpListener]::new($ip, $Port)
  $listener.Start()
  Write-Host "KABU LAB proxy listening on http://127.0.0.1:$Port/ (Ctrl+C to stop)"

  while ($true) {
    $client = $listener.AcceptTcpClient()
    $client.NoDelay = $true
    $client.ReceiveTimeout = $ClientReadTimeoutMs
    $client.SendTimeout = $ClientWriteTimeoutMs
    $stream = $null
    try {
      $request = Read-HttpRequest -Client $client
      $stream = $request.Stream
      $method = $request.Method
      $target = $request.Target
      $uri = [System.Uri]::new("http://127.0.0.1:$Port$target")
      $query = Parse-QueryString $uri.Query
      Handle-Request -Method $method -Path $uri.AbsolutePath -Query $query -Body $request.Body -Stream $stream
    } catch {
      try {
        Send-Json $stream 502 @{ ok = $false; error = "proxy failed"; detail = (Get-DeepErrorMessage $_) }
      } catch {}
    } finally {
      try { $client.Close() } catch {}
    }
  }
} finally {
  try { if ($listener) { $listener.Stop() } } catch {}
  try { $http.Dispose() } catch {}
  try { $handler.Dispose() } catch {}
}

