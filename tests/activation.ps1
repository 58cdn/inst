# No real licensing queries, activation, browser launch or settings changes.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path $root 'scripts/activation.ps1'
. $source -LibOnly
function Assert($Condition,$Message) { if (-not $Condition) { throw $Message } }
function Reject([scriptblock]$Block) { try { & $Block | Out-Null } catch { return }; throw 'Expected failure' }
$script:queries=0; $script:opens=0; $script:platforms=0
function Assert-ActivationPlatform { $script:platforms++ }
function Read-ActivationProducts {
  $script:queries++
  return @([pscustomobject]@{Name='Windows mock';LicenseStatus=1;PartialProductKey='SECRET';ProductKey='FULL-SECRET'})
}
function Start-Process { param($FilePath,$ErrorAction) $script:opens++; $script:lastUri=$FilePath }
$r=Invoke-ActivationAction
Assert ($r.Result -eq 'Queried' -and $r.Products[0].Status -eq 'Licensed') 'Default status'
Assert ($script:queries -eq 1 -and $script:opens -eq 0) 'Default launched something'
Assert (($r | ConvertTo-Json -Depth 5) -notmatch 'SECRET|ProductKey') 'Output leaked key fields'
foreach ($i in 0..6) {
  $r=ConvertTo-ActivationStatus @(@{Name='mock';LicenseStatus=$i})
  Assert ($r.Result -eq 'Queried' -and $r.Products[0].Code -eq $i) "Bad license code $i"
}
foreach ($value in @($null,7,-1,'garbage')) {
  $r=ConvertTo-ActivationStatus @(@{Name='mock';LicenseStatus=$value})
  Assert ($r.Result -eq 'Unknown' -and $null -eq $r.Products[0].Code) 'Unknown reported as licensed'
}
$r=ConvertTo-ActivationStatus @()
Assert ($r.Result -eq 'Unknown' -and $r.Products.Count -eq 0) 'Empty result'
$r=ConvertTo-ActivationStatus @(@{Name='one';LicenseStatus=1},@{Name='two';LicenseStatus=0})
Assert ($r.Products.Count -eq 2 -and $r.Products[1].Status -eq 'Unlicensed') 'Multiple products collapsed'
$before=$script:platforms
$r=Invoke-ActivationAction -DryRun
Assert ($script:queries -eq 1 -and $script:platforms -eq $before) 'DryRun queried system'
foreach ($a in @('Settings','Troubleshoot','LicenseHelp','MasReference')) {
  $r=Invoke-ActivationAction -Action $a
  Assert ($r.Result -eq 'Reference' -and $script:opens -eq 0) 'Reference auto opened'
  $r=Invoke-ActivationAction -Action $a -Open -DryRun
  Assert ($r.Result -eq 'Preview' -and $script:opens -eq 0) 'DryRun opened link'
}
foreach ($a in @('settings','Troubleshoot','LicenseHelp','MasReference')) {
  $r=Invoke-ActivationAction -Action $a -Open
  Assert ($r.Result -eq 'OpenRequested' -and $script:lastUri -eq $r.Uri) 'Explicit open routing'
}
Assert ($script:opens -eq 4) 'Unexpected open count'
Reject { Invoke-ActivationAction -Action Bad }
Reject { Invoke-ActivationAction -Open }
Reject { Open-ActivationLink 'https://example.org/script.ps1' }
function Start-Process { throw 'mock opener failure' }
Reject { Invoke-ActivationAction -Action Settings -Open }
function Read-ActivationProducts { throw 'mock query failure' }
Reject { Invoke-ActivationAction }
# Verify real CIM adapter requests only selected fields, with no full-key query.
& {
  . $source -LibOnly
  function Get-CimInstance {
    param($ClassName,$Namespace,$Filter,$Property,$OperationTimeoutSec,$ErrorAction)
    Assert ($ClassName -eq 'SoftwareLicensingProduct' -and $Namespace -eq 'root/cimv2') 'Wrong CIM class'
    Assert (($Property -join ',') -eq 'Name,LicenseStatus') 'Sensitive properties requested'
    Assert ($Filter -match '55c92734-d682-4d71-983e-d6ec3f16059f' -and $Filter -match 'PartialProductKey IS NOT NULL') 'Missing Windows/product filter'
    Assert ($OperationTimeoutSec -eq 15) 'Unbounded CIM request'
  }
  Read-ActivationProducts
}
if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
  & {
    . $source -LibOnly
    function Get-CimInstance { return @{Version='6.3.9600';ProductType=1;BuildNumber=9600} }
    Reject { Assert-ActivationPlatform }
    function Get-CimInstance { return @{Version='10.0.26100';ProductType=3;BuildNumber=26100} }
    Reject { Assert-ActivationPlatform }
    function Get-CimInstance { return @{Version='10.0.26100';ProductType=1;BuildNumber=26100} }
    Assert-ActivationPlatform
  }
  $engine=(Get-Process -Id $PID).Path
  $env:INST_NO_TTY='1'; $env:INST_NO_UPDATE_CHECK='1'
  $beforePath=[Environment]::GetEnvironmentVariable('Path','User')
  $output=& $engine -NoProfile -File (Join-Path $root 'install.ps1') -Activation -DryRun 2>&1 | Out-String
  Assert ($LASTEXITCODE -eq 0 -and $output -match 'activation.ps1' -and $output -match 'activation.cmd' -and $output -match 'activation.md') 'Installer forwarding'
  $output=& $engine -NoProfile -File (Join-Path $root 'install.ps1') -WindowsManagement -Activation -DryRun 2>&1 | Out-String
  Assert ($LASTEXITCODE -eq 0 -and $output -match 'activation.ps1' -and $output -match 'winmanage.ps1') 'Combined installer forwarding'
  Assert ([Environment]::GetEnvironmentVariable('Path','User') -ceq $beforePath) 'DryRun changed PATH'
  $output=& cmd.exe /d /c ('"{0}" -Action MasReference -Open -DryRun' -f (Join-Path $root 'scripts/activation.cmd')) 2>&1 | Out-String
  Assert ($LASTEXITCODE -eq 0 -and $output -match 'Preview' -and $output -match 'github.com/massgravel') 'CMD forwarding'
  $old=$ErrorActionPreference; $ErrorActionPreference='Continue'
  try {
    $output=& cmd.exe /d /c ('"{0}" -Action Invalid' -f (Join-Path $root 'scripts/activation.cmd')) 2>&1 | Out-String
    $code=$LASTEXITCODE
  } finally { $ErrorActionPreference=$old }
  Assert ($code -ne 0) 'CMD swallowed validation failure'
}
'PASS: activation status mapping, no key output, explicit allowlisted links, dry-run, error propagation, CIM and launcher mocks'
exit 0
