$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$names = @('INST_REGION','INST_NO_TTY','INST_NO_UPDATE_CHECK','INST_RAW_BASE_URL','INST_SELECTED_BASE_URL','INST_FORCE_UPDATE')
$saved = @{}
foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('inst-menu-' + [Guid]::NewGuid().ToString('N'))
function Assert([bool]$Value, [string]$Message) { if (-not $Value) { throw $Message } }
try {
  $env:INST_REGION = 'global'; $env:INST_NO_TTY = '1'; $env:INST_NO_UPDATE_CHECK = '1'
  $env:INST_RAW_BASE_URL = ''; $env:INST_SELECTED_BASE_URL = ''; $env:INST_FORCE_UPDATE = ''
  . (Join-Path $root 'scripts/install-windows.ps1') -LibOnly
  New-Item -ItemType Directory -Path $scratch | Out-Null
  $menuText = (Write-MainMenu 6>&1 | Out-String)
  $keys = @([regex]::Matches($menuText, '(?m)^ *([0-9]+)  ') | ForEach-Object { $_.Groups[1].Value }) -join ','
  Assert ($keys -ceq '1,2,3,4,5,6,7,8,9,10,11,12,13,14,0') "Menu keys: $keys"
  Assert (([regex]::Matches($menuText, '(?m)^---- \[')).Count -eq 5) 'Missing category separators'
  Assert (-not $menuText.Contains('pyenv') -and -not $menuText.Contains('Hermes')) 'Main menu contains long hints'
  $hint = Write-MenuLine 2 'Python 环境' 'pyenv / Python' 6>&1 | Out-String
  Assert ($hint -match 'Python 环境\r?\n     pyenv / Python') 'Submenu hint is not on its own line'
  Assert ((Compare-InstVersion '1.2.10' '1.2.9') -gt 0) 'Numeric comparison'
  foreach ($bad in @('1.2','01.2.3','1.2.3.4','1.2.3-beta','<html>error</html>','9999999999.1.1',"1.2.3`n1.2.4")) {
    Assert (-not (Test-ReleaseVersion $bad)) "Invalid version accepted: $bad"
  }
  'PASS: single-column menu, separators, literal 00, hints and strict versions'

  $script:Calls = @(); $script:Mode = 'ok'; $script:Reply = '9.9.9'
  function Invoke-RestMethod {
    param([string]$Uri, [int]$TimeoutSec, [switch]$UseBasicParsing, [hashtable]$Headers)
    $script:Calls += $Uri
    if ($script:Mode -eq 'offline') { throw 'simulated timeout' }
    if ($script:Mode -eq 'fallback' -and $Uri -notlike 'https://raw.githubusercontent.com/*') { return '<html>error</html>' }
    return $script:Reply
  }
  $env:INST_NO_UPDATE_CHECK = ''; $script:InstBase = 'https://inst.linux.yun'
  Assert ((Get-RemoteVersion) -eq '9.9.9') 'Lookup failed'
  Assert ($script:RemoteVersionSource -eq $script:InstBase) 'Wrong source'
  Assert ((Get-RemoteVersion) -eq '9.9.9' -and $script:Calls.Count -eq 1) 'Cache performed request'
  $script:Reply = '9.9.10'
  Assert ((Get-RemoteVersion -Refresh) -eq '9.9.10') 'Refresh used stale value'
  $script:Mode = 'fallback'
  Assert ((Get-RemoteVersion -Refresh) -eq '9.9.10') 'Fallback failed'
  Assert ($script:RemoteVersionSource -eq 'https://raw.githubusercontent.com/58cdn/inst/master') 'Wrong fallback'
  $env:INST_RAW_BASE_URL = 'https://custom.invalid'; $script:InstBase = $env:INST_RAW_BASE_URL
  $script:Mode = 'offline'; $script:Calls = @()
  Assert ((Get-RemoteVersion -Refresh) -eq '' -and $script:Calls.Count -eq 1) 'Explicit source fell back'
  Assert ((Get-RemoteVersion) -eq '' -and $script:Calls.Count -eq 1) 'Failure not cached'
  Assert ((Get-OnlineVersionLabel) -eq '不可用') 'Offline status'
  $env:INST_NO_UPDATE_CHECK = '1'
  Assert ((Get-RemoteVersion -Refresh) -eq '' -and $script:Calls.Count -eq 1) 'Disabled request'
  Assert ((Get-OnlineVersionLabel) -eq '已关闭') 'Disabled status'
  'PASS: lookup, caching, refresh, fallback, explicit source, offline and disabled modes'

  $env:INST_NO_UPDATE_CHECK = ''; $script:Mode = 'ok'; $script:Reply = '9.9.9'
  $script:UpdateTarget = Join-Path $scratch 'inst.ps1'
  $original = "# standalone`n`$InstVersion = '1.0.0'`n"
  [IO.File]::WriteAllText($script:UpdateTarget, $original)
  function Get-SelfUpdateTarget { return $script:UpdateTarget }
  function Get-RemoteScript([string]$Base) {
    Assert ($Base -eq 'https://custom.invalid') 'Update ignored verified source'
    return $script:Payload
  }
  $script:Payload = "# standalone`n`$InstVersion = '9.9.8'`n"
  $failed = $false
  try { Update-Installer } catch { $failed = $true }
  Assert $failed 'Manifest mismatch accepted'
  Assert ([IO.File]::ReadAllText($script:UpdateTarget) -eq $original) 'Mismatch changed installed file'
  Assert (-not (Test-Path "$script:UpdateTarget.bak")) 'Mismatch created backup'
  $script:Payload = "# standalone`n`$InstVersion = '9.9.9'`n"
  Update-Installer
  Assert ((Get-ScriptVersion ([IO.File]::ReadAllText($script:UpdateTarget))) -eq '9.9.9') 'Update version'
  Assert ([IO.File]::ReadAllText("$script:UpdateTarget.bak") -eq $original) 'Backup content'
  $bytes = [IO.File]::ReadAllBytes($script:UpdateTarget)
  Assert ($bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) 'Update lost PS 5.1 BOM'
  $env:INST_NO_UPDATE_CHECK = '1'; $env:INST_FORCE_UPDATE = '1'
  $script:Payload = "# standalone`n`$InstVersion = '8.0.0'`n"
  $failed = $false
  try { Update-Installer } catch { $failed = $true }
  Assert $failed 'Downgrade accepted'
  Assert ((Get-ScriptVersion ([IO.File]::ReadAllText($script:UpdateTarget))) -eq '9.9.9') 'Downgrade changed installed file'
  'PASS: manifest consistency, source matching, backup, BOM and downgrade prevention'

  $script:ChoiceIndex = 0; $script:Opened = 0
  function Read-Choice([string]$Prompt, [string]$Default) {
    $script:ChoiceIndex++
    if ($script:ChoiceIndex -eq 1) { return '13' }; return '0'
  }
  function Show-Banner { }
  function Show-UpdateMenu { $script:Opened++ }
  Show-MainMenu
  Assert ($script:Opened -eq 1) '13 dispatch confused with 0'
  'PASS: 13 opens updates; 0 exits'
} finally {
  foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
  Remove-Item -LiteralPath $scratch -Recurse -Force -ErrorAction SilentlyContinue
}
exit 0
