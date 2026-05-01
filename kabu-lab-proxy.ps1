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
#   /name?code=7203&market=JP

param(
  [int]$Port = 8791
)

$ErrorActionPreference = "Stop"
$ProxyVersion = "2026-04-25.4"

try {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
} catch {}

try {
  [System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
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
      Send-Body $Stream 200 (Invoke-UpstreamJsonAny $urls)
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

