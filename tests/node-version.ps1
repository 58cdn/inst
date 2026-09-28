$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
. (Join-Path $root 'scripts\install-windows.ps1') -LibOnly | Out-Null

if ($NodeMirrorCn -ne 'https://cdn.npmmirror.com/binaries/node/') {
  throw "Unexpected Node mirror: $NodeMirrorCn"
}

$Arch = 'x64'
$catalog = @(
  [pscustomobject]@{ version = 'v24.21.0'; lts = 'Krypton'; files = @('win-x64-zip') }
  [pscustomobject]@{ version = 'v24.20.0'; lts = 'Iron'; files = @('win-x64-zip') }
  [pscustomobject]@{ version = 'v25.0.0'; lts = $false; files = @('win-x64-zip') }
  [pscustomobject]@{ version = 'v24.19.0-rc1'; lts = 'Iron'; files = @('win-x64-zip') }
)
function Test-NodeAssetUrl([string]$Url) {
  return (-not $Url.Contains('/v24.21.0/'))
}
$selected = Get-NodeLtsVersionFromCatalog $catalog 'https://mirror.example/node/'
if (-not $selected -or $selected.Version -ne '24.20.0') {
  throw "The first unavailable LTS was not skipped: $($selected | Out-String)"
}
if ($selected.Url -ne 'https://mirror.example/node/v24.20.0/node-v24.20.0-win-x64.zip') {
  throw "Unexpected Node asset URL: $($selected.Url)"
}

# Invoke-RestMethod returns a System.Object[] for a JSON array. Keep this as a
# single returned value so the test catches accidental @(...) re-wrapping.
$script:NodeVersionCatalog = $catalog
$NodeMirrorOfficial = 'https://mirror.example/node/'
function Invoke-RestMethod {
  [CmdletBinding()]
  param([string]$Uri, [int]$TimeoutSec, [switch]$UseBasicParsing)
  return ,$script:NodeVersionCatalog
}
$resolved = Resolve-NodeLtsVersion (Join-Path $env:TEMP 'nvm-test\nvm.exe') $false
if (-not $resolved -or $resolved.Version -ne '24.20.0') {
  throw "JSON array LTS resolution failed: $($resolved | Out-String)"
}
'PASS: Node LTS selection skips an unavailable mirror asset and unwraps JSON arrays'
exit 0
