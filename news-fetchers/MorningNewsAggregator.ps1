function Add-NewsSourceStatus {
  param(
    [System.Collections.IList]$List,
    [string]$Source,
    [bool]$Ok,
    [int]$Count = 0,
    [bool]$Skipped = $false,
    [string]$Detail = ""
  )

  [void]$List.Add([ordered]@{
    source = $Source
    ok = $Ok
    count = $Count
    skipped = $Skipped
    detail = $Detail
  })
}

function Get-MorningStockNewsSummary {
  param(
    [string[]]$Codes = @(),
    [int]$Days = 3,
    [string[]]$Terms = @(),
    [string]$XSignalsJson = "",
    [string[]]$LargeCapCodes = @()
  )

  $safeDays = [Math]::Min([Math]::Max($Days, 1), 31)
  $cleanCodes = @($Codes | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -match "^\d{4}$" } | Select-Object -Unique)
  $cleanTerms = @($Terms | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique)
  $items = New-Object System.Collections.Generic.List[object]
  $statuses = New-Object System.Collections.Generic.List[object]

  if ($cleanCodes.Count) {
    $tdnetCount = 0
    $tdnetErrors = New-Object System.Collections.Generic.List[string]
    foreach ($code in $cleanCodes) {
      try {
        $fetched = @(Get-TdnetNewsItems -Code $code -Days $safeDays)
        foreach ($item in $fetched) { $items.Add($item) }
        $tdnetCount += $fetched.Count
      } catch {
        $tdnetErrors.Add("${code}: $(Get-DeepErrorMessage $_)")
      }
    }
    Add-NewsSourceStatus -List $statuses -Source "TDnet" -Ok ($tdnetErrors.Count -eq 0) -Count $tdnetCount -Detail ($tdnetErrors -join " | ")
  } else {
    Add-NewsSourceStatus -List $statuses -Source "TDnet" -Ok $false -Count 0 -Skipped $true -Detail "codes parameter is empty"
  }

  try {
    $fetched = @(Get-EdinetNewsItems -Codes $cleanCodes -Days $safeDays)
    foreach ($item in $fetched) { $items.Add($item) }
    Add-NewsSourceStatus -List $statuses -Source "EDINET" -Ok $true -Count $fetched.Count
  } catch {
    $detail = Get-DeepErrorMessage $_
    $skipped = $detail -match "API key is not configured"
    Add-NewsSourceStatus -List $statuses -Source "EDINET" -Ok $false -Count 0 -Skipped $skipped -Detail $detail
  }

  try {
    $fetched = @(Get-YahooFinanceNewsItems -Codes $cleanCodes -Days $safeDays)
    foreach ($item in $fetched) { $items.Add($item) }
    Add-NewsSourceStatus -List $statuses -Source "Yahoo!ファイナンス" -Ok $true -Count $fetched.Count
  } catch {
    Add-NewsSourceStatus -List $statuses -Source "Yahoo!ファイナンス" -Ok $false -Count 0 -Detail (Get-DeepErrorMessage $_)
  }

  try {
    $xJson = Get-XSignalSourceJson -SignalsJson $XSignalsJson
    if ([string]::IsNullOrWhiteSpace($xJson)) {
      Add-NewsSourceStatus -List $statuses -Source "X" -Ok $false -Count 0 -Skipped $true -Detail "KABU_LAB_X_SIGNALS_JSON or xSignals query is not configured"
    } else {
      $fetched = @(Get-XReactionItems -Codes $cleanCodes -Terms $cleanTerms -SignalsJson $xJson)
      foreach ($item in $fetched) { $items.Add($item) }
      Add-NewsSourceStatus -List $statuses -Source "X" -Ok $true -Count $fetched.Count -Detail "SNS反応・未確認情報として処理"
    }
  } catch {
    Add-NewsSourceStatus -List $statuses -Source "X" -Ok $false -Count 0 -Detail (Get-DeepErrorMessage $_)
  }

  if ($cleanCodes.Count) {
    try {
      $fetched = @(Get-PriceRankingNewsItems -Codes $cleanCodes -LargeCapCodes $LargeCapCodes)
      foreach ($item in $fetched) { $items.Add($item) }
      Add-NewsSourceStatus -List $statuses -Source "PTS・株価ランキング" -Ok $true -Count $fetched.Count
    } catch {
      Add-NewsSourceStatus -List $statuses -Source "PTS・株価ランキング" -Ok $false -Count 0 -Detail (Get-DeepErrorMessage $_)
    }
  } else {
    Add-NewsSourceStatus -List $statuses -Source "PTS・株価ランキング" -Ok $false -Count 0 -Skipped $true -Detail "codes parameter is empty"
  }

  return ConvertTo-MorningStockNewsSummary -Items @($items.ToArray()) -SourceStatus @($statuses.ToArray())
}
