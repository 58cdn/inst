$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
# Import definitions only; -LibOnly returns before any action runs.
. (Join-Path $root 'scripts\install-windows.ps1') -LibOnly | Out-Null
$pyenvCommand = Find-PyenvCommand
if ($pyenvCommand -and $pyenvCommand.Name -notin @('pyenv.bat','pyenv.cmd','pyenv.ps1','pyenv.exe')) { throw "Unexpected pyenv entry: $($pyenvCommand.Name)" }
$catalog = @('Available versions:', '  3.9.9', '3.9.10', '3.13.8', '3.14.2', '3.15.0rc1', '3.14.2-win32', 'pypy3.11-7.3.20')
foreach ($case in @(@('latest','3.14.2'), @('3.9','3.9.10'), @('3.13.8','3.13.8'))) {
  $actual = Resolve-PythonVersion $case[0] $catalog
  if ($actual -ne $case[1]) { throw "Version resolution failed for $($case[0]): $actual" }
}
foreach ($requested in @('3.99','3.15.0rc1','--force')) {
  $failed = $false
  try { Resolve-PythonVersion $requested $catalog | Out-Null } catch { $failed = $true }
  if (-not $failed) { throw "Invalid version accepted: $requested" }
}
$failed = $false
try { Invoke-NodeCommand $env:ComSpec @('/d','/c','exit 17') } catch { $failed = $true }
if (-not $failed) { throw 'Nonzero native exit code was ignored' }
foreach ($bad in @('http://example.com', 'ftp://example.com', 'example.com')) {
  $failed = $false
  try { Assert-HttpsUrl $bad 'url' } catch { $failed = $true }
  if (-not $failed) { throw "Non-HTTPS URL accepted: $bad" }
}
if ((Compare-InstVersion '1.10.0' '1.9.3') -le 0) { throw 'Version comparison is not numeric' }

# A standalone Node.js without nvm-windows: a dry run only warns and keeps previewing, a real run
# stops before changing anything. Runs last because it replaces installer functions.
$Region = 'global'
$fakeBin = Join-Path $env:TEMP ('inst-node-' + [guid]::NewGuid().ToString('N'))
$savedPath = $env:Path
try {
  New-Item -ItemType Directory -Path $fakeBin | Out-Null
  [IO.File]::WriteAllBytes((Join-Path $fakeBin 'node.exe'), [byte[]]@())
  $env:Path = "$fakeBin;$env:Path"
  function Find-Nvm { $null }
  $Prefix = Join-Path $fakeBin 'prefix'
  $DryRun = [switch]$true
  $plan = Install-Node 6>&1 | Out-String
  if (-not ($plan.Contains($fakeBin) -and $plan.Contains('nvm-noinstall.zip') -and $plan.Contains('install lts'))) { throw "The dry run stopped at the Node.js conflict`n$plan" }
  if (Test-Path -LiteralPath $Prefix) { throw 'The dry run created the prefix directory' }
  $DryRun = [switch]$false
  # Should the check ever go missing, these make the real run fail instead of installing.
  function Save-Download { throw 'unexpected download' }
  function Set-UserEnv { throw 'unexpected environment change' }
  function Add-UserPath { throw 'unexpected PATH change' }
  function Invoke-Native { throw 'unexpected command' }
  $failed = $false
  try { Install-Node 6>$null } catch { $failed = "$_".Contains($fakeBin) }
  if (-not $failed) { throw 'A standalone Node.js did not stop the real run' }
} finally {
  $DryRun = [switch]$false
  $env:Path = $savedPath
  Remove-Item -LiteralPath $fakeBin -Recurse -Force -ErrorAction SilentlyContinue
}
'PASS: numeric version selection, prerelease rejection, HTTPS validation, native command failure and the standalone Node.js conflict'
# The native failure test left $LASTEXITCODE at 17; report success to the caller.
exit 0
