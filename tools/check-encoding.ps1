$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Split-Path -Parent $scriptDir
$utf8 = New-Object System.Text.UTF8Encoding($false, $true)
$patterns = @(
  [char]0xFFFD,
  [char]0x7E3A, # mojibake marker often seen for Japanese UTF-8 text
  [char]0x7E67,
  [char]0x7E5D,
  [char]0x9B2E,
  [char]0x9A6B,
  [char]0x7AB6
)

$files = Get-ChildItem -Path $root -Recurse -File -Include *.html,*.css,*.js,*.ps1,*.bat,*.md,*.json |
  Where-Object { $_.FullName -notmatch '\\(\.git|out|json|node_modules)\\' }

$failed = @()
foreach ($file in $files) {
  try {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $text = $utf8.GetString($bytes)
    foreach ($pattern in $patterns) {
      if ($text.Contains([string]$pattern)) {
        $code = 'U+{0:X4}' -f [int][char]$pattern
        $failed += "$($file.FullName): suspicious character $code"
        break
      }
    }
  } catch {
    $failed += "$($file.FullName): invalid UTF-8"
  }
}

if ($failed.Count -gt 0) {
  $failed | ForEach-Object { Write-Host $_ }
  exit 1
}

Write-Host "Encoding check OK: $($files.Count) files"
