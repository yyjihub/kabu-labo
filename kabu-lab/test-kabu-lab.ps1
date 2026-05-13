param(
  [string]$Proxy = "http://127.0.0.1:8809",
  [string]$QuoteSymbol = "7203.T",
  [string]$JpxCode = "1333",
  [string]$IrCode = "7203"
)

$ErrorActionPreference = "Stop"
$base = $Proxy.TrimEnd("/")
$failures = 0
$warnings = 0

function Read-ErrorBody {
  param([object]$ErrorRecord)

  try {
    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) { return "" }
    $reader = [System.IO.StreamReader]::new($response.GetResponseStream())
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
  } catch {
    return ""
  }
}

function Get-ErrorStatusCode {
  param([object]$ErrorRecord)

  try {
    $response = $ErrorRecord.Exception.Response
    if ($null -eq $response) { return $null }
    return [int]$response.StatusCode
  } catch {
    return $null
  }
}

function Invoke-ProxyJson {
  param(
    [string]$Path,
    [int]$TimeoutSec = 30
  )

  $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec $TimeoutSec "$base$Path"
  return $response.Content | ConvertFrom-Json
}

function Write-CheckResult {
  param(
    [string]$Level,
    [string]$Name,
    [string]$Message
  )

  Write-Host ("[{0}] {1}: {2}" -f $Level, $Name, $Message)
}

function Run-RequiredCheck {
  param(
    [string]$Name,
    [scriptblock]$Check
  )

  try {
    $message = & $Check
    Write-CheckResult "OK" $Name $message
  } catch {
    $script:failures++
    $body = Read-ErrorBody $_
    if ($body) {
      Write-CheckResult "NG" $Name $body
    } else {
      Write-CheckResult "NG" $Name $_.Exception.Message
    }
  }
}

function Run-OptionalCheck {
  param(
    [string]$Name,
    [scriptblock]$Check
  )

  try {
    $message = & $Check
    Write-CheckResult "OK" $Name $message
  } catch {
    $script:warnings++
    $body = Read-ErrorBody $_
    if ($body) {
      Write-CheckResult "WARN" $Name $body
    } else {
      Write-CheckResult "WARN" $Name $_.Exception.Message
    }
  }
}

Run-RequiredCheck "health" {
  $data = Invoke-ProxyJson "/health" 5
  if (-not $data.ok) { throw "health returned ok=false" }
  "version=$($data.version), port=$($data.port), strictSources=$($data.strictSources)"
}

Run-RequiredCheck "input validation" {
  try {
    [void](Invoke-ProxyJson "/jpx/earnings?code=ABC" 5)
    throw "invalid code was accepted"
  } catch {
    $status = Get-ErrorStatusCode $_
    if ($status -eq 400) { return "invalid JPX code rejected with HTTP 400" }
    $body = Read-ErrorBody $_
    if ($body -notmatch "code must be a 4 digit Japanese stock code") { throw }
  }
  "invalid JPX code rejected"
}

Run-OptionalCheck "jpx earnings $JpxCode" {
  $data = Invoke-ProxyJson "/jpx/earnings?code=$JpxCode" 90
  if (-not $data.ok) { throw "jpx returned ok=false" }
  if (($data.sourceFileCount -as [int]) -le 0) { throw "no JPX source files parsed" }
  "date=$($data.date), latestKnown=$($data.latestKnownDate), files=$($data.sourceFileCount), rows=$($data.parsedRowCount)"
}

Run-OptionalCheck "quote $QuoteSymbol" {
  $symbol = [System.Uri]::EscapeDataString($QuoteSymbol)
  $data = Invoke-ProxyJson "/yahoo/quote?symbol=$symbol" 45
  $count = @($data.quoteResponse.result).Count
  if ($count -le 0) { throw "quote result is empty" }
  "results=$count"
}

Run-OptionalCheck "chart $QuoteSymbol" {
  $symbol = [System.Uri]::EscapeDataString($QuoteSymbol)
  $data = Invoke-ProxyJson "/yahoo/chart?symbol=$symbol&range=1mo&interval=1d" 60
  $result = @($data.chart.result) | Select-Object -First 1
  $count = @($result.timestamp).Count
  if ($count -le 0) { throw "chart timestamp is empty" }
  "bars=$count"
}

Run-OptionalCheck "tdnet ir $IrCode" {
  $data = Invoke-ProxyJson "/tdnet/ir?code=$IrCode&days=31" 60
  if ($null -eq $data.count) { throw "IR count is missing" }
  "count=$($data.count)"
}

Write-Host ("Summary: failures={0}, warnings={1}" -f $failures, $warnings)
if ($failures -gt 0) { exit 1 }
exit 0
