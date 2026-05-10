function Get-EdinetNewsItems {
  param(
    [string[]]$Codes = @(),
    [int]$Days = 3
  )

  $apiKey = [Environment]::GetEnvironmentVariable("EDINET_API_KEY", "User")
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    $apiKey = [Environment]::GetEnvironmentVariable("KABU_LAB_EDINET_API_KEY", "User")
  }
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    $apiKey = [Environment]::GetEnvironmentVariable("EDINET_API_KEY", "Process")
  }
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    $apiKey = [Environment]::GetEnvironmentVariable("KABU_LAB_EDINET_API_KEY", "Process")
  }
  if ([string]::IsNullOrWhiteSpace($apiKey)) {
    throw "EDINET API key is not configured. Set EDINET_API_KEY or KABU_LAB_EDINET_API_KEY."
  }

  $codeSet = @{}
  foreach ($code in @($Codes)) {
    $clean = ([string]$code).Trim()
    if ($clean -match "^\d{4}$") { $codeSet[$clean] = $true }
  }

  $items = New-Object System.Collections.Generic.List[object]
  $safeDays = [Math]::Min([Math]::Max($Days, 1), 31)
  $encodedKey = [System.Uri]::EscapeDataString($apiKey)

  for ($i = 0; $i -lt $safeDays; $i++) {
    $date = (Get-Date).Date.AddDays(-1 * $i)
    $dateText = $date.ToString("yyyy-MM-dd")
    $url = "https://api.edinet-fsa.go.jp/api/v2/documents.json?date=$dateText&type=2&Subscription-Key=$encodedKey"
    $json = Invoke-UpstreamJson $url
    $data = $json | ConvertFrom-Json
    foreach ($doc in @($data.results)) {
      $description = [string]$doc.docDescription
      if ([string]::IsNullOrWhiteSpace($description)) { continue }
      if ($description -notmatch "大量保有|変更報告書|有価証券報告書|半期報告書|四半期報告書|臨時報告書|内部統制報告書") { continue }

      $secCode = ([string]$doc.secCode).Trim()
      $code4 = ""
      if ($secCode -match "^(\d{4})") { $code4 = $Matches[1] }

      if ($codeSet.Count -gt 0) {
        $matched = $false
        if ($code4 -and $codeSet.ContainsKey($code4)) { $matched = $true }
        if (-not $matched) {
          foreach ($code in $codeSet.Keys) {
            if ($description -match [regex]::Escape($code)) { $matched = $true; break }
          }
        }
        if (-not $matched) { continue }
      }

      $submitText = [string]$doc.submitDateTime
      $publishedAt = $null
      $itemDate = $dateText
      $itemTime = ""
      $dt = [DateTime]::MinValue
      if (-not [string]::IsNullOrWhiteSpace($submitText) -and [DateTime]::TryParse($submitText, [ref]$dt)) {
        $publishedAt = $dt.ToString("o")
        $itemDate = $dt.ToString("yyyy-MM-dd")
        $itemTime = $dt.ToString("HH:mm")
      }

      $items.Add((New-StockNewsItem `
        -SourceId "edinet" `
        -SourceName "EDINET" `
        -SourceType "official" `
        -Reliability 0.95 `
        -Code $code4 `
        -Name ([string]$doc.filerName) `
        -Title $description `
        -Material $description `
        -Category (Get-StockNewsMaterialCategory $description) `
        -PublishedAt $publishedAt `
        -Date $itemDate `
        -Time $itemTime `
        -HasOfficialInfo $true `
        -OfficialInfoSource "EDINET" `
        -Caution "EDINET提出書類です。大量保有や変更報告書は提出者・対象会社・保有目的を本文で確認してください。" `
        -Raw $doc))
    }
  }

  return $items
}
