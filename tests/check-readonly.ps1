$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($file in @('install.ps1', 'scripts\install-windows.ps1')) {
  $tokens = $null
  $errors = $null
  [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count) { throw "$file`n$($errors | Out-String)" }
}
# The bootstrap must stay ASCII so `irm | iex` works regardless of the console code page.
if ([IO.File]::ReadAllBytes((Join-Path $root 'install.ps1')) | Where-Object { $_ -gt 127 }) { throw 'install.ps1 contains non-ASCII bytes' }
$bytes = [IO.File]::ReadAllBytes((Join-Path $root 'scripts\install-windows.ps1'))
if ($bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { throw 'install-windows.ps1 must be saved as UTF-8 with BOM for Windows PowerShell 5.1' }

$env:INST_NO_UPDATE_CHECK = '1'
$env:INST_NO_TTY = '1'
$beforePath = $env:PATH
$beforeUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$probe = Join-Path $PSScriptRoot ('check-' + [guid]::NewGuid().ToString('N'))
$output = & (Join-Path $root 'install.ps1') -Check -All -Desktop -Prefix $probe -DesktopDir $probe 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) { throw "Check failed with exit code $LASTEXITCODE`n$output" }
if (Test-Path -LiteralPath $probe) { throw 'Check created a directory' }
if ($env:PATH -cne $beforePath) { throw 'Check changed process PATH' }
if ([Environment]::GetEnvironmentVariable('Path', 'User') -cne $beforeUserPath) { throw 'Check changed user PATH' }
if ($output -notmatch 'node' -or $output -match '\+ npm') { throw "Unexpected check output`n$output" }
'PASS: PowerShell parsing, encodings and read-only check precedence'
