param(
  [string]$ConfigPath = "",
  [string]$OutDir = "",
  [int]$Port = 8809,
  [int]$TimeoutSec = 120
)

$ErrorActionPreference = "Stop"
$ExpectedProxyVersion = "2026-05-13.1"

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $PSScriptRoot "morning-news-config.json"
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $PSScriptRoot "out\morning-news"
}

function Read-JsonFile {
  param([string]$Path)

  if (-not (Test-Path -LiteralPath $Path)) {
    throw "config file not found: $Path"
  }
  return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function ConvertTo-Array {
  param([object]$Value)

  if ($null -eq $Value) { return @() }
  if ($Value -is [System.Array]) { return @($Value) }
  return @($Value)
}

function Join-QueryList {
  param([object[]]$Values)

  return (@($Values) | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ } | Select-Object -Unique) -join ","
}

function Test-KabuLabProxy {
  param([int]$TargetPort)

  try {
    $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 "http://127.0.0.1:$TargetPort/health"
    $json = $response.Content | ConvertFrom-Json
    return [ordered]@{
      ok = [bool]$json.ok
      version = [string]$json.version
      port = $TargetPort
    }
  } catch {
    return [ordered]@{
      ok = $false
      version = ""
      port = $TargetPort
    }
  }
}

function Find-FreeLocalPort {
  param([int]$StartPort)

  for ($candidate = $StartPort; $candidate -lt ($StartPort + 50); $candidate++) {
    $listener = $null
    try {
      $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Parse("127.0.0.1"), $candidate)
      $listener.Start()
      return $candidate
    } catch {
    } finally {
      try { if ($listener) { $listener.Stop() } } catch {}
    }
  }
  throw "free local port not found"
}

function Start-KabuLabProxyForJob {
  param([int]$PreferredPort)

  $health = Test-KabuLabProxy -TargetPort $PreferredPort
  if ($health.ok -and $health.version -eq $ExpectedProxyVersion) {
    return [ordered]@{ port = $PreferredPort; process = $null; reused = $true }
  }

  $jobPort = if ($health.ok) { Find-FreeLocalPort -StartPort 8810 } else { $PreferredPort }
  $proxyPath = Join-Path $PSScriptRoot "kabu-lab-proxy.ps1"
  if (-not (Test-Path -LiteralPath $proxyPath)) { throw "proxy script not found: $proxyPath" }

  $process = Start-Process -FilePath powershell -WindowStyle Hidden -PassThru -ArgumentList @(
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    $proxyPath,
    "-Port",
    "$jobPort"
  )

  $deadline = (Get-Date).AddSeconds(12)
  do {
    Start-Sleep -Milliseconds 400
    $started = Test-KabuLabProxy -TargetPort $jobPort
    if ($started.ok -and $started.version -eq $ExpectedProxyVersion) {
      return [ordered]@{ port = $jobPort; process = $process; reused = $false }
    }
  } while ((Get-Date) -lt $deadline)

  try { if ($process -and -not $process.HasExited) { Stop-Process -Id $process.Id -Force } } catch {}
  throw "proxy did not start on port $jobPort"
}

function Resolve-OptionalPath {
  param([string]$Path)

  if ([string]::IsNullOrWhiteSpace($Path)) { return "" }
  if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
  return (Join-Path $PSScriptRoot $Path)
}

function ConvertTo-MarkdownTable {
  param([object[]]$Rows)

  $columns = @("銘柄コード", "銘柄名", "株価変動率", "出来高変化", "材料", "情報源", "公式情報の有無", "SNSでの反応", "注意点")
  if (-not $Rows -or $Rows.Count -eq 0) { return "_該当なし_" }
  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add("| " + ($columns -join " | ") + " |")
  $lines.Add("| " + (($columns | ForEach-Object { "---" }) -join " | ") + " |")
  foreach ($row in $Rows) {
    $values = foreach ($column in $columns) {
      $value = [string]$row.$column
      ($value -replace "\|", "/" -replace "\r?\n", " ").Trim()
    }
    $lines.Add("| " + ($values -join " | ") + " |")
  }
  return ($lines -join "`n")
}

function ConvertTo-MorningNewsMarkdown {
  param([object]$Summary)

  $out = New-Object System.Collections.Generic.List[string]
  $out.Add("# 日本株 朝ニュースまとめ")
  $out.Add("")
  $out.Add("- 生成日時: $($Summary.fetchedAt)")
  $out.Add("- 取得件数: $($Summary.count)")
  $out.Add("")
  $out.Add("## 取得元ステータス")
  foreach ($status in @($Summary.sourceStatus)) {
    $state = if ($status.ok) { "OK" } elseif ($status.skipped) { "SKIP" } else { "NG" }
    $detail = if ([string]::IsNullOrWhiteSpace([string]$status.detail)) { "" } else { " - $($status.detail)" }
    $out.Add("- $($status.source): $state / $($status.count)件$detail")
  }
  $out.Add("")
  $out.Add("## 急騰銘柄トップ10")
  $out.Add((ConvertTo-MarkdownTable @($Summary.finalOutput.topGainers)))
  $out.Add("")
  $out.Add("## 急落銘柄ワースト10")
  $out.Add((ConvertTo-MarkdownTable @($Summary.finalOutput.topLosers)))
  $out.Add("")
  $out.Add("## 大きく動いた大型株")
  $out.Add((ConvertTo-MarkdownTable @($Summary.finalOutput.largeCapMovers)))
  $out.Add("")
  $out.Add("## 市場全体の注目ニュース")
  $out.Add((ConvertTo-MarkdownTable @($Summary.finalOutput.marketHighlights)))
  $out.Add("")
  $out.Add("## 注意")
  $out.Add("- Xの情報はSNS反応または未確認情報として扱い、単独では事実扱いしません。")
  $out.Add("- 投資判断の前にTDnet、EDINET、企業IR、信頼できる報道で確認してください。")
  return ($out -join "`n")
}

$config = Read-JsonFile -Path $ConfigPath
$codes = @(ConvertTo-Array $config.codes)
$terms = @(ConvertTo-Array $config.terms)
$largeCaps = @(ConvertTo-Array $config.largeCapCodes)
$days = 3
if ($null -ne $config.days) { $days = [int]$config.days }
if (-not $codes.Count) { throw "config.codes is empty" }

$xSignalsJson = ""
$xSignalsPath = Resolve-OptionalPath ([string]$config.xSignalsJsonPath)
if ($xSignalsPath -and (Test-Path -LiteralPath $xSignalsPath)) {
  $xSignalsJson = Get-Content -LiteralPath $xSignalsPath -Raw -Encoding UTF8
}

$proxy = $null
try {
  $proxy = Start-KabuLabProxyForJob -PreferredPort $Port
  $params = [ordered]@{
    codes = Join-QueryList $codes
    terms = Join-QueryList $terms
    largeCaps = Join-QueryList $largeCaps
    days = "$days"
  }
  if (-not [string]::IsNullOrWhiteSpace($xSignalsJson)) { $params.xSignals = $xSignalsJson }

  $query = ($params.GetEnumerator() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Value) } | ForEach-Object {
    "$([System.Uri]::EscapeDataString([string]$_.Key))=$([System.Uri]::EscapeDataString([string]$_.Value))"
  }) -join "&"
  $url = "http://127.0.0.1:$($proxy.port)/news/morning?$query"
  $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec $TimeoutSec $url
  $summary = $response.Content | ConvertFrom-Json
  if (-not $summary.ok) { throw "morning news endpoint returned ok=false" }

  New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
  $stamp = (Get-Date).ToString("yyyy-MM-dd")
  $jsonPath = Join-Path $OutDir "morning-news-$stamp.json"
  $mdPath = Join-Path $OutDir "morning-news-$stamp.md"
  $response.Content | Set-Content -LiteralPath $jsonPath -Encoding UTF8
  ConvertTo-MorningNewsMarkdown -Summary $summary | Set-Content -LiteralPath $mdPath -Encoding UTF8

  Write-Host "Morning news generated"
  Write-Host "JSON: $jsonPath"
  Write-Host "Markdown: $mdPath"
  Write-Host "Items: $($summary.count)"
  foreach ($status in @($summary.sourceStatus)) {
    $state = if ($status.ok) { "OK" } elseif ($status.skipped) { "SKIP" } else { "NG" }
    Write-Host "Source: $($status.source) $state $($status.count)"
  }
} finally {
  try {
    if ($proxy -and $proxy.process -and -not $proxy.process.HasExited) {
      Stop-Process -Id $proxy.process.Id -Force
    }
  } catch {}
}
