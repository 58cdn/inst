$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
foreach ($file in @('install.ps1', 'scripts\install-windows.ps1')) {
  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$errors)
  if ($errors.Count) { throw "$file`n$($errors | Out-String)" }
  # PowerShell reads CJK letters right after "$name" as part of the variable name; write "${name}" there.
  $names = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -match '[^\x00-\x7F]' }, $true))
  if ($names.Count) { throw "$file uses non-ASCII variable names: $(($names | ForEach-Object { $_.Extent.Text }) -join ', ')" }
}
# The bootstrap must stay ASCII so `irm | iex` works regardless of the console code page.
if ([IO.File]::ReadAllBytes((Join-Path $root 'install.ps1')) | Where-Object { $_ -gt 127 }) { throw 'install.ps1 contains non-ASCII bytes' }
$bytes = [IO.File]::ReadAllBytes((Join-Path $root 'scripts\install-windows.ps1'))
if ($bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { throw 'install-windows.ps1 must be saved as UTF-8 with BOM for Windows PowerShell 5.1' }
$cmdText = [IO.File]::ReadAllText((Join-Path $root 'install.cmd'))
if ($cmdText -match 'if not defined INST_RAW_BASE_URL set') { throw 'install.cmd must not turn the default URL into an explicit override' }
if ($cmdText -notmatch 'INST_BOOTSTRAP_BASE') { throw 'install.cmd must use a separate bootstrap URL variable' }

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
