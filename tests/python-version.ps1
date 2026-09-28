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
'PASS: numeric version selection, prerelease rejection, HTTPS validation and native command failure'
