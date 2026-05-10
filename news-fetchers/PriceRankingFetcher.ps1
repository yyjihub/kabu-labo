function Get-DefaultLargeCapCodes {
  return @("7203", "6758", "9984", "8306", "6861", "8035", "4063", "6098", "9432", "9433", "7974", "6954", "6501", "8058", "8001", "8031", "4502", "4519", "4568", "6981")
}

function Get-YahooQuoteResultsForCodes {
  param([string[]]$Codes)

  $validCodes = @($Codes | Where-Object { ([string]$_) -match "^\d{4}$" } | Select-Object -Unique)
  if (-not $validCodes.Count) { return @() }
  $symbols = (($validCodes | ForEach-Object { "$_.T" }) -join ",")
  $encoded = [System.Uri]::EscapeDataString($symbols)
  $urls = @(
    "https://query2.finance.yahoo.com/v7/finance/quote?symbols=$encoded",
    "https://query1.finance.yahoo.com/v7/finance/quote?symbols=$encoded"
  )
  $json = $null
  try {
    $json = Invoke-UpstreamJsonAny $urls
  } catch {
    $json = ConvertTo-YahooQuoteFromYahooJapan -Symbols $symbols
  }
  $data = $json | ConvertFrom-Json
  return @($data.quoteResponse.result)
}

function Get-PriceRankingNewsItems {
  param(
    [string[]]$Codes = @(),
    [string[]]$LargeCapCodes = @()
  )

  $largeSet = @{}
  foreach ($code in @(Get-DefaultLargeCapCodes)) { $largeSet[$code] = $true }
  foreach ($code in @($LargeCapCodes)) {
    $clean = ([string]$code).Trim()
    if ($clean -match "^\d{4}$") { $largeSet[$clean] = $true }
  }

  $items = New-Object System.Collections.Generic.List[object]
  foreach ($quote in @(Get-YahooQuoteResultsForCodes -Codes $Codes)) {
    $symbol = [string]$quote.symbol
    $code = ""
    if ($symbol -match "^(\d{4})\.T$") { $code = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($code)) { continue }

    $name = [string]$quote.longName
    if ([string]::IsNullOrWhiteSpace($name)) { $name = [string]$quote.shortName }

    $price = $null
    $prev = $null
    $pct = $null
    if ($null -ne $quote.regularMarketPrice) { $price = [double]$quote.regularMarketPrice }
    if ($null -ne $quote.regularMarketPreviousClose) { $prev = [double]$quote.regularMarketPreviousClose }
    elseif ($null -ne $quote.previousClose) { $prev = [double]$quote.previousClose }
    if ($null -ne $quote.regularMarketChangePercent) {
      $pct = [double]$quote.regularMarketChangePercent
    } elseif ($null -ne $price -and $null -ne $prev -and $prev -ne 0) {
      $pct = (($price - $prev) / $prev) * 100
    }
    if ($null -eq $pct) { continue }

    $volumeRatio = $null
    $volume = $null
    $avgVolume = $null
    if ($null -ne $quote.regularMarketVolume) { $volume = [double]$quote.regularMarketVolume }
    if ($null -ne $quote.averageDailyVolume3Month) { $avgVolume = [double]$quote.averageDailyVolume3Month }
    elseif ($null -ne $quote.averageDailyVolume10Day) { $avgVolume = [double]$quote.averageDailyVolume10Day }
    if ($null -ne $volume -and $null -ne $avgVolume -and $avgVolume -gt 0) {
      $volumeRatio = $volume / $avgVolume
    }

    $bucket = if ($pct -ge 0) { "gainer" } else { "loser" }
    $absPct = [Math]::Abs([double]$pct)
    $isLargeCap = $largeSet.ContainsKey($code)
    if ($null -ne $quote.marketCap -and [double]$quote.marketCap -ge 1000000000000) { $isLargeCap = $true }
    $material = if ($pct -ge 0) { "株価上昇 $([Math]::Round([double]$pct, 2))%" } else { "株価下落 $([Math]::Round([double]$pct, 2))%" }
    if ($null -ne $volumeRatio -and $volumeRatio -ge 2) { $material = "$material / 出来高急増 $([Math]::Round([double]$volumeRatio, 2))倍" }
    if ($isLargeCap -and $absPct -ge 1.5) { $material = "$material / 大型株の大きな値動き" }

    $items.Add((New-StockNewsItem `
      -SourceId "price_ranking" `
      -SourceName "PTS・株価ランキング" `
      -SourceType "market" `
      -Reliability 0.72 `
      -Code $code `
      -Name $name `
      -Title "$code $name $material" `
      -Material $material `
      -Category "株価ランキング" `
      -PublishedAt ([DateTime]::Now.ToString("o")) `
      -PriceChangePct $pct `
      -VolumeChangeRatio $volumeRatio `
      -HasOfficialInfo $false `
      -Caution "Yahoo系quoteから算出した株価・出来高の動きです。PTS固有の価格は別データで確認してください。" `
      -MovementBucket $bucket `
      -IsLargeCap $isLargeCap `
      -Raw $quote))
  }

  return $items
}
