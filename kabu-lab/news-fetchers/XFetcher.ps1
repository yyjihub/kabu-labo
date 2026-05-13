function ConvertFrom-XSignalJson {
  param([string]$Json)

  if ([string]::IsNullOrWhiteSpace($Json)) { return @() }
  try {
    $parsed = $Json | ConvertFrom-Json
    if ($parsed -is [System.Array]) { return @($parsed) }
    if ($parsed.signals) { return @($parsed.signals) }
    return @($parsed)
  } catch {
    throw "invalid X signal JSON"
  }
}

function Get-XSignalSourceJson {
  param([string]$SignalsJson)

  if (-not [string]::IsNullOrWhiteSpace($SignalsJson)) { return $SignalsJson }
  $envJson = [Environment]::GetEnvironmentVariable("KABU_LAB_X_SIGNALS_JSON", "Process")
  if ([string]::IsNullOrWhiteSpace($envJson)) {
    $envJson = [Environment]::GetEnvironmentVariable("KABU_LAB_X_SIGNALS_JSON", "User")
  }
  return $envJson
}

function Get-XReactionItems {
  param(
    [string[]]$Codes = @(),
    [string[]]$Terms = @(),
    [string]$SignalsJson = ""
  )

  $json = Get-XSignalSourceJson -SignalsJson $SignalsJson
  if ([string]::IsNullOrWhiteSpace($json)) { return @() }

  $codeSet = @{}
  foreach ($code in @($Codes)) {
    $clean = ([string]$code).Trim()
    if ($clean -match "^\d{4}$") { $codeSet[$clean] = $true }
  }
  $termSet = @{}
  foreach ($term in @($Terms)) {
    $cleanTerm = ([string]$term).Trim()
    if ($cleanTerm) { $termSet[$cleanTerm] = $true }
  }

  $items = New-Object System.Collections.Generic.List[object]
  foreach ($signal in @(ConvertFrom-XSignalJson $json)) {
    $code = ([string]$signal.code).Trim()
    $term = ([string]$signal.term).Trim()
    if ([string]::IsNullOrWhiteSpace($term)) { $term = ([string]$signal.name).Trim() }
    if ([string]::IsNullOrWhiteSpace($term) -and $code) { $term = $code }

    if ($codeSet.Count -gt 0 -and $code -and -not $codeSet.ContainsKey($code)) { continue }
    if ($codeSet.Count -gt 0 -and -not $code -and $termSet.Count -gt 0 -and -not $termSet.ContainsKey($term)) { continue }

    $mentions = $null
    $baseline = $null
    $surgeRatio = $null
    if ($null -ne $signal.mentions) { $mentions = [int]$signal.mentions }
    if ($null -ne $signal.baseline) { $baseline = [double]$signal.baseline }
    if ($null -ne $signal.surgeRatio) { $surgeRatio = [double]$signal.surgeRatio }
    elseif ($null -ne $signal.changeRatio) { $surgeRatio = [double]$signal.changeRatio }
    elseif ($null -ne $mentions -and $null -ne $baseline -and $baseline -gt 0) { $surgeRatio = [Math]::Round($mentions / $baseline, 2) }

    if ($null -ne $mentions -and $mentions -lt 20 -and ($null -eq $surgeRatio -or $surgeRatio -lt 2.0)) { continue }

    $reactionParts = New-Object System.Collections.Generic.List[string]
    if ($null -ne $mentions) { $reactionParts.Add("投稿 $mentions 件") }
    if ($null -ne $surgeRatio) { $reactionParts.Add("平常比 $([Math]::Round([double]$surgeRatio, 2)) 倍") }
    if ($reactionParts.Count -eq 0) { $reactionParts.Add("投稿数急増を検知") }
    $reaction = $reactionParts -join " / "
    $name = [string]$signal.name
    $title = "Xで「$term」の投稿が急増"

    $items.Add((New-StockNewsItem `
      -SourceId "x_social" `
      -SourceName "X" `
      -SourceType "social" `
      -Reliability 0.35 `
      -Code $code `
      -Name $name `
      -Title $title `
      -Material $title `
      -Category "SNS反応" `
      -Url ([string]$signal.url) `
      -PublishedAt ([DateTime]::Now.ToString("o")) `
      -HasOfficialInfo $false `
      -SnsReaction $reaction `
      -SnsMentions $mentions `
      -SnsSurgeRatio $surgeRatio `
      -VerificationStatus "unconfirmed" `
      -Caution "Xの話題化は未確認情報として扱います。単独では事実・材料扱いせず、公式開示または信頼できる報道で裏取りしてください。" `
      -Raw $signal))
  }

  return $items
}
