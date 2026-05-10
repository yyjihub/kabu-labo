function Get-StockNewsMaterialCategory {
  param([string]$Title)

  $text = [string]$Title
  if ($text -match "決算短信|四半期決算|中間決算|通期決算|Financial Results") { return "決算" }
  if ($text -match "業績予想|上方修正|下方修正|予想の修正|修正予想|Forecast") { return "業績修正" }
  if ($text -match "配当|剰余金|株主還元|優待") { return "配当/還元" }
  if ($text -match "自己株|自社株|ToSTNeT") { return "自社株買い" }
  if ($text -match "公開買付|TOB|買収|合併|会社分割|株式交換|株式移転|資本業務提携|M&A") { return "M&A/再編" }
  if ($text -match "大量保有|変更報告書") { return "大量保有" }
  if ($text -match "有価証券報告書|半期報告書|四半期報告書|臨時報告書|内部統制報告書") { return "EDINET開示" }
  if ($text -match "ランキング|値上がり|値下がり|急騰|急落|出来高") { return "株価ランキング" }
  if ($text -match "市場|日経平均|TOPIX|グロース|東証|為替|金利") { return "市場ニュース" }
  if ($text -match "X|SNS|投稿|話題|急増") { return "SNS反応" }
  if ($text -match "KPI|月次") { return "月次/KPI" }
  return "その他"
}

function ConvertTo-StockNewsDateTime {
  param(
    [string]$Date,
    [string]$Time
  )

  if ([string]::IsNullOrWhiteSpace($Date)) { return $null }
  $text = $Date.Trim()
  if (-not [string]::IsNullOrWhiteSpace($Time)) { $text = "$text $($Time.Trim())" }
  $formats = @("yyyy-MM-dd HH:mm", "yyyy-MM-dd H:mm", "yyyy-MM-dd")
  $dt = [DateTime]::MinValue
  foreach ($format in $formats) {
    if ([DateTime]::TryParseExact($text, $format, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$dt)) {
      return $dt.ToString("o")
    }
  }
  if ([DateTime]::TryParse($text, [ref]$dt)) { return $dt.ToString("o") }
  return $null
}

function New-StockNewsItem {
  param(
    [string]$SourceId,
    [string]$SourceName,
    [string]$SourceType,
    [double]$Reliability,
    [string]$Code = "",
    [string]$Name = "",
    [string]$Title,
    [string]$Material = "",
    [string]$Category = "",
    [string]$Url = "",
    [string]$PublishedAt = $null,
    [string]$Date = "",
    [string]$Time = "",
    [Nullable[double]]$PriceChangePct = $null,
    [Nullable[double]]$VolumeChangeRatio = $null,
    [bool]$HasOfficialInfo = $false,
    [string]$OfficialInfoSource = "",
    [string]$SnsReaction = "",
    [Nullable[int]]$SnsMentions = $null,
    [Nullable[double]]$SnsSurgeRatio = $null,
    [string]$Caution = "",
    [string]$VerificationStatus = "verified",
    [string]$MovementBucket = "",
    [bool]$IsLargeCap = $false,
    [object]$Raw = $null
  )

  if ([string]::IsNullOrWhiteSpace($Category)) { $Category = Get-StockNewsMaterialCategory $Title }
  if ([string]::IsNullOrWhiteSpace($Material)) { $Material = $Title }
  if ([string]::IsNullOrWhiteSpace($PublishedAt)) { $PublishedAt = ConvertTo-StockNewsDateTime -Date $Date -Time $Time }
  if ([string]::IsNullOrWhiteSpace($Date) -and -not [string]::IsNullOrWhiteSpace($PublishedAt)) {
    try { $Date = ([DateTime]::Parse($PublishedAt)).ToString("yyyy-MM-dd") } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($SourceType)) { $SourceType = "reporting" }
  if ($SourceType -eq "official") { $HasOfficialInfo = $true }
  if ([string]::IsNullOrWhiteSpace($OfficialInfoSource) -and $HasOfficialInfo) { $OfficialInfoSource = $SourceName }
  if ($SourceType -eq "social") {
    $VerificationStatus = "unconfirmed"
    if ([string]::IsNullOrWhiteSpace($Caution)) {
      $Caution = "Xの投稿増加は事実確認済み材料ではありません。必ず公式開示または報道で裏取りしてください。"
    }
  }

  $idParts = @($SourceId, $Code, $PublishedAt, $Title, $Url) | ForEach-Object { ([string]$_).Trim() }
  $id = (($idParts -join "|") -replace "\s+", " ").Trim()

  [ordered]@{
    id = $id
    sourceId = $SourceId
    sourceName = $SourceName
    sourceType = $SourceType
    sourceReliability = [Math]::Round($Reliability, 2)
    verificationStatus = $VerificationStatus
    code = $Code
    name = $Name
    title = $Title
    material = $Material
    category = $Category
    url = $Url
    publishedAt = $PublishedAt
    date = $Date
    time = $Time
    priceChangePct = $PriceChangePct
    volumeChangeRatio = $VolumeChangeRatio
    hasOfficialInfo = $HasOfficialInfo
    officialInfoSource = $OfficialInfoSource
    snsReaction = $SnsReaction
    snsMentions = $SnsMentions
    snsSurgeRatio = $SnsSurgeRatio
    caution = $Caution
    movementBucket = $MovementBucket
    isLargeCap = $IsLargeCap
    sources = @($SourceName)
    raw = $Raw
  }
}

function Get-StockNewsDedupeKey {
  param([object]$Item)

  $code = ([string]$Item.code).Trim()
  $url = ([string]$Item.url).Trim().ToLowerInvariant()
  if ($url) { return "url|$url" }
  $date = ""
  if ($Item.publishedAt) {
    try { $date = ([DateTime]::Parse([string]$Item.publishedAt)).ToString("yyyy-MM-dd") } catch {}
  } elseif ($Item.date) {
    $date = [string]$Item.date
  }
  $titleValue = $Item.title
  if ($null -eq $titleValue -or [string]::IsNullOrWhiteSpace([string]$titleValue)) { $titleValue = $Item.material }
  $title = ([string]$titleValue).ToLowerInvariant()
  $title = ($title -replace "\s+", "" -replace "[\p{P}\p{S}]", "")
  if ($title.Length -gt 90) { $title = $title.Substring(0, 90) }
  return "text|$code|$date|$title"
}

function Get-StockNewsSourceRank {
  param([object]$Item)

  switch ([string]$Item.sourceType) {
    "official" { return 400 }
    "reporting" { return 300 }
    "market" { return 220 }
    "social" { return 100 }
    default { return 0 }
  }
}

function Merge-StockNewsItem {
  param(
    [object]$Current,
    [object]$Incoming
  )

  if ($null -eq $Current) { return $Incoming }
  $currentReliability = 0.0
  $incomingReliability = 0.0
  if ($null -ne $Current.sourceReliability) { $currentReliability = [double]$Current.sourceReliability }
  if ($null -ne $Incoming.sourceReliability) { $incomingReliability = [double]$Incoming.sourceReliability }
  $currentScore = (Get-StockNewsSourceRank $Current) + $currentReliability
  $incomingScore = (Get-StockNewsSourceRank $Incoming) + $incomingReliability
  $primary = $Current
  $secondary = $Incoming
  if ($incomingScore -gt $currentScore) {
    $primary = $Incoming
    $secondary = $Current
  }

  $sourceSet = [ordered]@{}
  foreach ($source in @($primary.sources) + @($secondary.sources) + @($primary.sourceName) + @($secondary.sourceName)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$source)) { $sourceSet[[string]$source] = $true }
  }
  $sources = @($sourceSet.Keys)

  $primary.sources = $sources
  $primary.sourceName = ($sources -join " / ")
  $primaryReliability = 0.0
  $secondaryReliability = 0.0
  if ($null -ne $primary.sourceReliability) { $primaryReliability = [double]$primary.sourceReliability }
  if ($null -ne $secondary.sourceReliability) { $secondaryReliability = [double]$secondary.sourceReliability }
  $primary.sourceReliability = [Math]::Max($primaryReliability, $secondaryReliability)
  $primary.hasOfficialInfo = [bool]($primary.hasOfficialInfo -or $secondary.hasOfficialInfo)
  if ([string]::IsNullOrWhiteSpace([string]$primary.officialInfoSource)) { $primary.officialInfoSource = $secondary.officialInfoSource }
  if ([string]::IsNullOrWhiteSpace([string]$primary.snsReaction)) { $primary.snsReaction = $secondary.snsReaction }
  if ($null -eq $primary.snsMentions) { $primary.snsMentions = $secondary.snsMentions }
  if ($null -eq $primary.snsSurgeRatio) { $primary.snsSurgeRatio = $secondary.snsSurgeRatio }
  if ([string]::IsNullOrWhiteSpace([string]$primary.caution)) { $primary.caution = $secondary.caution }
  if ($null -eq $primary.priceChangePct) { $primary.priceChangePct = $secondary.priceChangePct }
  if ($null -eq $primary.volumeChangeRatio) { $primary.volumeChangeRatio = $secondary.volumeChangeRatio }
  if ([string]::IsNullOrWhiteSpace([string]$primary.movementBucket)) { $primary.movementBucket = $secondary.movementBucket }
  $primary.isLargeCap = [bool]($primary.isLargeCap -or $secondary.isLargeCap)
  return $primary
}

function Remove-DuplicateStockNewsItems {
  param([object[]]$Items)

  $map = @{}
  foreach ($item in @($Items)) {
    if ($null -eq $item) { continue }
    $key = Get-StockNewsDedupeKey $item
    $map[$key] = Merge-StockNewsItem -Current $map[$key] -Incoming $item
  }
  return @($map.Values | Sort-Object `
    @{ Expression = { if ($_.publishedAt) { try { [DateTime]::Parse([string]$_.publishedAt) } catch { [DateTime]::MinValue } } else { [DateTime]::MinValue } }; Descending = $true }, `
    @{ Expression = { if ($null -ne $_.sourceReliability) { [double]$_.sourceReliability } else { 0 } }; Descending = $true })
}

function Format-StockNewsPercent {
  param([Nullable[double]]$Value)
  if ($null -eq $Value) { return "未取得" }
  $sign = if ($Value -gt 0) { "+" } else { "" }
  return "$sign$([Math]::Round([double]$Value, 2))%"
}

function Format-StockNewsVolumeChange {
  param([Nullable[double]]$Value)
  if ($null -eq $Value) { return "未取得" }
  return "$([Math]::Round([double]$Value, 2))倍"
}

function ConvertTo-StockNewsOutputRow {
  param([object]$Item)

  [ordered]@{
    "銘柄コード" = if ([string]::IsNullOrWhiteSpace([string]$Item.code)) { "市場全体" } else { [string]$Item.code }
    "銘柄名" = if ([string]::IsNullOrWhiteSpace([string]$Item.name)) { "-" } else { [string]$Item.name }
    "株価変動率" = Format-StockNewsPercent $Item.priceChangePct
    "出来高変化" = Format-StockNewsVolumeChange $Item.volumeChangeRatio
    "材料" = [string]$Item.material
    "情報源" = [string]$Item.sourceName
    "公式情報の有無" = if ($Item.hasOfficialInfo) { "あり" } else { "なし" }
    "SNSでの反応" = if ([string]::IsNullOrWhiteSpace([string]$Item.snsReaction)) { "未検出" } else { [string]$Item.snsReaction }
    "注意点" = if ([string]::IsNullOrWhiteSpace([string]$Item.caution)) { "公式情報・一次情報で確認してください。" } else { [string]$Item.caution }
  }
}

function ConvertTo-MorningStockNewsSummary {
  param(
    [object[]]$Items,
    [object[]]$SourceStatus
  )

  $deduped = @(Remove-DuplicateStockNewsItems $Items)
  $topGainers = @($deduped | Where-Object { $_.priceChangePct -ne $null } | Sort-Object @{ Expression = { [double]$_.priceChangePct }; Descending = $true } | Select-Object -First 10)
  $topLosers = @($deduped | Where-Object { $_.priceChangePct -ne $null } | Sort-Object @{ Expression = { [double]$_.priceChangePct }; Descending = $false } | Select-Object -First 10)
  $largeCapMovers = @($deduped | Where-Object { $_.isLargeCap -and $_.priceChangePct -ne $null } | Sort-Object @{ Expression = { [Math]::Abs([double]$_.priceChangePct) }; Descending = $true } | Select-Object -First 10)
  $marketHighlights = @($deduped | Where-Object { [string]$_.sourceType -ne "social" } | Select-Object -First 20)

  [ordered]@{
    ok = $true
    fetchedAt = [DateTime]::Now.ToString("o")
    columns = @("銘柄コード", "銘柄名", "株価変動率", "出来高変化", "材料", "情報源", "公式情報の有無", "SNSでの反応", "注意点")
    count = $deduped.Count
    sourceStatus = @($SourceStatus)
    sections = [ordered]@{
      official = @($deduped | Where-Object { $_.sourceType -eq "official" })
      reporting = @($deduped | Where-Object { $_.sourceType -eq "reporting" })
      market = @($deduped | Where-Object { $_.sourceType -eq "market" })
      social = @($deduped | Where-Object { $_.sourceType -eq "social" })
      unconfirmed = @($deduped | Where-Object { $_.verificationStatus -eq "unconfirmed" })
    }
    finalOutput = [ordered]@{
      topGainers = @($topGainers | ForEach-Object { ConvertTo-StockNewsOutputRow $_ })
      topLosers = @($topLosers | ForEach-Object { ConvertTo-StockNewsOutputRow $_ })
      largeCapMovers = @($largeCapMovers | ForEach-Object { ConvertTo-StockNewsOutputRow $_ })
      marketHighlights = @($marketHighlights | ForEach-Object { ConvertTo-StockNewsOutputRow $_ })
      rows = @($deduped | ForEach-Object { ConvertTo-StockNewsOutputRow $_ })
    }
    items = $deduped
  }
}
