function Get-TdnetNewsItems {
  param(
    [string]$Code,
    [int]$Days = 3
  )

  $items = New-Object System.Collections.Generic.List[object]
  foreach ($item in @(Get-TdnetItems -Code $Code -Days $Days)) {
    $publishedAt = ConvertTo-StockNewsDateTime -Date $item.date -Time $item.time
    $items.Add((New-StockNewsItem `
      -SourceId "tdnet" `
      -SourceName "TDnet" `
      -SourceType "official" `
      -Reliability 0.98 `
      -Code $Code `
      -Name $item.name `
      -Title $item.title `
      -Material $item.title `
      -Category (Get-StockNewsMaterialCategory $item.title) `
      -Url $item.url `
      -PublishedAt $publishedAt `
      -Date $item.date `
      -Time $item.time `
      -HasOfficialInfo $true `
      -OfficialInfoSource "TDnet" `
      -Caution "TDnetの適時開示です。数値や条件はPDF本文で確認してください。" `
      -Raw $item))
  }
  return $items
}
