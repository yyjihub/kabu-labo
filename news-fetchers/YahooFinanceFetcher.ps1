function Convert-YahooFinanceNewsDate {
  param([string]$Text)

  if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
  $now = Get-Date
  $m = [regex]::Match($Text, "(\d{4})/(\d{1,2})/(\d{1,2})(?:\s+(\d{1,2}):(\d{2}))?")
  if ($m.Success) {
    try {
      $hour = if ($m.Groups[4].Success) { [int]$m.Groups[4].Value } else { 0 }
      $minute = if ($m.Groups[5].Success) { [int]$m.Groups[5].Value } else { 0 }
      return ([DateTime]::new([int]$m.Groups[1].Value, [int]$m.Groups[2].Value, [int]$m.Groups[3].Value, $hour, $minute, 0)).ToString("o")
    } catch {}
  }
  $m = [regex]::Match($Text, "(?<!\d)(\d{1,2})/(\d{1,2})(?:\s+(\d{1,2}):(\d{2}))?")
  if ($m.Success) {
    try {
      $dt = [DateTime]::new($now.Year, [int]$m.Groups[1].Value, [int]$m.Groups[2].Value, 0, 0, 0)
      if ($dt -gt $now.AddDays(7)) { $dt = $dt.AddYears(-1) }
      if ($m.Groups[3].Success) { $dt = $dt.AddHours([int]$m.Groups[3].Value).AddMinutes([int]$m.Groups[4].Value) }
      return $dt.ToString("o")
    } catch {}
  }
  return $null
}

function Get-YahooFinanceNewsLinks {
  param(
    [string]$Url,
    [int]$Limit = 20
  )

  $links = New-Object System.Collections.Generic.List[object]
  $html = Invoke-UpstreamText -Url $Url -EncodingName "UTF-8"
  $opts = [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  $anchors = [regex]::Matches($html, "<a[^>]+href\s*=\s*[""']([^""']+)[""'][^>]*>(.*?)</a>", $opts)
  $seen = @{}
  foreach ($a in $anchors) {
    $href = [System.Net.WebUtility]::HtmlDecode($a.Groups[1].Value).Trim()
    $text = ConvertFrom-CellHtml $a.Groups[2].Value
    $text = ($text -replace "\s+", " ").Trim()
    if ([string]::IsNullOrWhiteSpace($href) -or [string]::IsNullOrWhiteSpace($text)) { continue }
    if ($text.Length -lt 8 -or $text -match "ログイン|検索|トップ|一覧|もっと見る|Yahoo!ファイナンス") { continue }
    if ($href -notmatch "/news|news\.yahoo\.co\.jp|finance\.yahoo\.co\.jp/news") { continue }
    if ($href -notmatch "^https?://") {
      if ($href.StartsWith("/")) { $href = "https://finance.yahoo.co.jp$href" }
      else { $href = "https://finance.yahoo.co.jp/$href" }
    }
    if ($seen.ContainsKey($href)) { continue }
    $seen[$href] = $true
    $links.Add([ordered]@{
      title = $text
      url = $href
      publishedAt = Convert-YahooFinanceNewsDate $text
    })
    if ($links.Count -ge $Limit) { break }
  }
  return $links
}

function Get-YahooFinanceDisclosureNewsItems {
  param(
    [string[]]$Codes = @(),
    [int]$Days = 3
  )

  $items = New-Object System.Collections.Generic.List[object]
  $cutoff = (Get-Date).Date.AddDays(-1 * ([Math]::Max($Days, 1) - 1))
  foreach ($code in @($Codes)) {
    if ($code -notmatch "^\d{4}$") { continue }
    try {
      foreach ($item in @(Get-YahooDisclosureItems -Code $code -Limit 40)) {
        $itemDate = [DateTime]::MinValue
        if (-not [DateTime]::TryParseExact([string]$item.date, "yyyy-MM-dd", [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$itemDate)) { continue }
        if ($itemDate -lt $cutoff) { continue }
        $items.Add((New-StockNewsItem `
          -SourceId "yahoo_disclosure" `
          -SourceName "Yahoo!ファイナンス TDnet開示" `
          -SourceType "reporting" `
          -Reliability 0.86 `
          -Code $code `
          -Name $item.name `
          -Title $item.title `
          -Material $item.title `
          -Category (Get-StockNewsMaterialCategory $item.title) `
          -Url $item.url `
          -PublishedAt (ConvertTo-StockNewsDateTime -Date $item.date -Time $item.time) `
          -Date $item.date `
          -Time $item.time `
          -HasOfficialInfo $true `
          -OfficialInfoSource "TDnet" `
          -Caution "Yahoo!ファイナンス経由のTDnet開示です。最終確認はTDnetまたはPDF本文で行ってください。" `
          -Raw $item))
      }
    } catch {}
  }
  return $items
}

function Get-YahooFinanceArticleNewsItems {
  param(
    [string[]]$Codes = @(),
    [int]$Limit = 20
  )

  $items = New-Object System.Collections.Generic.List[object]
  try {
    foreach ($link in @(Get-YahooFinanceNewsLinks -Url "https://finance.yahoo.co.jp/news" -Limit $Limit)) {
      $items.Add((New-StockNewsItem `
        -SourceId "yahoo_market_news" `
        -SourceName "Yahoo!ファイナンス" `
        -SourceType "reporting" `
        -Reliability 0.74 `
        -Title $link.title `
        -Material $link.title `
        -Category (Get-StockNewsMaterialCategory $link.title) `
        -Url $link.url `
        -PublishedAt $link.publishedAt `
        -HasOfficialInfo $false `
        -Caution "報道・配信記事です。重要事実は企業開示や取引所情報で確認してください。" `
        -Raw $link))
    }
  } catch {}

  foreach ($code in @($Codes)) {
    if ($code -notmatch "^\d{4}$") { continue }
    $name = ""
    try { $name = Get-CompanyName -Code $code -Market "JP" } catch {}
    $url = "https://finance.yahoo.co.jp/quote/$code.T/news"
    try {
      foreach ($link in @(Get-YahooFinanceNewsLinks -Url $url -Limit 12)) {
        $items.Add((New-StockNewsItem `
          -SourceId "yahoo_stock_news" `
          -SourceName "Yahoo!ファイナンス 個別株ニュース" `
          -SourceType "reporting" `
          -Reliability 0.74 `
          -Code $code `
          -Name $name `
          -Title $link.title `
          -Material $link.title `
          -Category (Get-StockNewsMaterialCategory $link.title) `
          -Url $link.url `
          -PublishedAt $link.publishedAt `
          -HasOfficialInfo $false `
          -Caution "個別株ニュースです。株価材料として扱う前に公式開示の有無を確認してください。" `
          -Raw $link))
      }
    } catch {}
  }
  return $items
}

function Get-YahooFinanceRankingNewsItems {
  param([string[]]$Codes = @())

  $items = New-Object System.Collections.Generic.List[object]
  $pages = @(
    [ordered]@{ Url = "https://finance.yahoo.co.jp/stocks/ranking/up?market=tokyo"; Label = "値上がりランキング"; Bucket = "gainer" },
    [ordered]@{ Url = "https://finance.yahoo.co.jp/stocks/ranking/down?market=tokyo"; Label = "値下がりランキング"; Bucket = "loser" },
    [ordered]@{ Url = "https://finance.yahoo.co.jp/stocks/ranking/volume?market=tokyo"; Label = "出来高ランキング"; Bucket = "volume" }
  )

  foreach ($page in $pages) {
    try {
      $html = Invoke-UpstreamText -Url $page.Url -EncodingName "UTF-8"
      foreach ($code in @($Codes)) {
        if ($code -notmatch "^\d{4}$") { continue }
        if ($html -notmatch [regex]::Escape("$code.T") -and $html -notmatch "(?<!\d)$code(?!\d)") { continue }
        $name = ""
        try { $name = Get-CompanyName -Code $code -Market "JP" } catch {}
        $items.Add((New-StockNewsItem `
          -SourceId "yahoo_ranking" `
          -SourceName "Yahoo!ファイナンス ランキング" `
          -SourceType "market" `
          -Reliability 0.72 `
          -Code $code `
          -Name $name `
          -Title "$code がYahoo!ファイナンスの$($page.Label)に掲載" `
          -Material "$($page.Label)掲載" `
          -Category "株価ランキング" `
          -Url $page.Url `
          -PublishedAt ([DateTime]::Now.ToString("o")) `
          -HasOfficialInfo $false `
          -Caution "ランキング掲載は市場データ上の動きです。材料は公式開示・報道と突き合わせてください。" `
          -MovementBucket $page.Bucket `
          -Raw $page))
      }
    } catch {}
  }
  return $items
}

function Get-YahooFinanceNewsItems {
  param(
    [string[]]$Codes = @(),
    [int]$Days = 3
  )

  $items = New-Object System.Collections.Generic.List[object]
  foreach ($item in @(Get-YahooFinanceDisclosureNewsItems -Codes $Codes -Days $Days)) { $items.Add($item) }
  foreach ($item in @(Get-YahooFinanceArticleNewsItems -Codes $Codes -Limit 20)) { $items.Add($item) }
  foreach ($item in @(Get-YahooFinanceRankingNewsItems -Codes $Codes)) { $items.Add($item) }
  return $items
}
