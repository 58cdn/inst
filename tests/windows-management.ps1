# All system adapters are replaced BEFORE actions. Only temporary JSON files are written.
$ErrorActionPreference='Stop'
$root=Split-Path $PSScriptRoot -Parent
$source=Join-Path $root 'scripts/winmanage.ps1'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($source,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
$names=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.VariableExpressionAst] -and $n.VariablePath.UserPath -match '[^\x00-\x7F]'},$true))
if ($names.Count) { throw 'Non-ASCII variable names' }
. $source -LibOnly
function Assert($value,$message) { if (-not $value) { throw $message } }
function Reject([scriptblock]$body,[string]$pattern) {
  try { & $body | Out-Null } catch { Assert ($_.ToString() -match $pattern) "Unexpected error: $_"; return }
  throw "Expected rejection: $pattern"
}
$temp=Join-Path ([IO.Path]::GetTempPath()) ('wm-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp | Out-Null
$script:writes=0; $script:ignored=$false; $script:failWrite=$false
function Reset-State {
  $script:state=[pscustomobject]@{
    Machine='mock-machine'; OSVersion='10.0.22631'; Build=22631; ProductType=1; Edition='Professional'; Admin=$true; Managed=$false
    Update=@{Exists=$false;Value=$null}; Defender=@{DisableRealtimeMonitoring=$false}
    Protection=@{IsTamperProtected=$false;AMRunningMode='Normal';RealTimeProtectionEnabled=$true}; Issues=@()
  }
}
# System adapter mocks: no registry, service, Defender or privilege calls.
function Get-WmState { return $script:state }
function Set-WmValue($Target,$Value) {
  $script:writes++
  if ($script:failWrite) { throw 'mock write failed' }
  if ($script:ignored) { return }
  if ($Target -eq 'Update') { $script:state.Update=@{Exists=$Value.Exists;Value=$Value.Value} }
  else { $script:state.Defender.DisableRealtimeMonitoring=$Value.Value; $script:state.Protection.RealTimeProtectionEnabled=(-not $Value.Value) }
}
function Get-WmUpdateValue { return $script:state.Update }
function Get-MpPreference { return $script:state.Defender }
function Get-MpComputerStatus { return $script:state.Protection }
try {
  Reset-State
  $s=Invoke-WmAction
  Assert ($s.Machine -eq 'mock-machine' -and $script:writes -eq 0) 'Default must be read only'
  foreach ($a in @('UpdateDisable','UpdateEnable','DefenderDisable','DefenderEnable')) {
    $r=Invoke-WmAction -Action $a
    Assert ($r.Result -eq 'Preview') 'Missing Apply must preview'
    $r=Invoke-WmAction -Action $a -Apply -DryRun -BackupPath (Join-Path $temp 'no.json')
    Assert ($r.Result -eq 'Preview') 'DryRun must win'
  }
  Assert ($script:writes -eq 0 -and @(Get-ChildItem $temp).Count -eq 0) 'Preview wrote data'
  $r=Invoke-WmAction -Action updatedisable
  Assert ($r.Target -eq 'Update' -and $r.Value -eq 1) 'Case-insensitive action routing'
  Reject { Invoke-WmAction -Action Bad } '未知'
  Reject { Invoke-WmAction -Action DefenderUninstall -Apply } '不支持'
  Reject { Invoke-WmAction -Action SecurityCenterDisable -Apply } '不支持'
  foreach ($case in @(@('Admin',$false,'管理员'),@('Managed',$true,'组织'),@('Edition','Core','白名单'),@('ProductType',3,'Server'),@('Build',9600,'旧版'),@('OSVersion','12.0.0','旧版'))) {
    Reset-State; $script:state.($case[0])=$case[1]
    Reject { Invoke-WmAction -Action UpdateDisable -Apply -BackupPath (Join-Path $temp 'blocked.json') } $case[2]
  }
  foreach ($tamper in @($true,$null)) {
    Reset-State; $script:state.Protection.IsTamperProtected=$tamper
    Reject { Invoke-WmAction -Action DefenderDisable -Apply } '篡改'
  }
  Reset-State; $script:state.Protection.AMRunningMode='Passive'
  Reject { Invoke-WmAction -Action DefenderEnable -Apply } '主动模式'
  Reset-State; $script:state.Defender=$null
  Reject { Invoke-WmAction -Action DefenderEnable -Apply } '不可用'
  Assert ($script:writes -eq 0) 'Blocked operation wrote system state'
  Reset-State
  Reject { Invoke-WmAction -Action UpdateDisable -Apply } 'BackupPath'
  $before=Join-Path $temp 'original.json'
  $r=Invoke-WmAction -Action UpdateDisable -Apply -BackupPath $before
  Assert ($r.Result -eq 'Verified' -and $script:state.Update.Value -eq 1) 'Disable update'
  $count=$script:writes
  Reject { Invoke-WmAction -Action UpdateEnable -Apply -BackupPath $before } 'exists|存在'
  Assert ($script:writes -eq $count) 'Backup overwrite caused mutation'
  $r=Invoke-WmAction -Action Restore -RestorePath $before -Apply -BackupPath (Join-Path $temp 'undo.json')
  Assert (-not $script:state.Update.Exists) 'Restore must preserve original absence'
  $r=Invoke-WmAction -Action Restore -RestorePath (Join-Path $temp 'undo.json') -Apply -BackupPath (Join-Path $temp 'redo.json')
  Assert ($script:state.Update.Value -eq 1) 'Restore present DWORD'
  $r=Invoke-WmAction -Action UpdateEnable -Apply -BackupPath (Join-Path $temp 'enable.json')
  Assert ($script:state.Update.Value -eq 0) 'Enable update'
  $def=Join-Path $temp 'def.json'
  $r=Invoke-WmAction -Action DefenderDisable -Apply -BackupPath $def
  Assert (-not $script:state.Protection.RealTimeProtectionEnabled) 'Disable Defender mock'
  $r=Invoke-WmAction -Action Restore -RestorePath $def -Apply -BackupPath (Join-Path $temp 'def-undo.json')
  Assert $script:state.Protection.RealTimeProtectionEnabled 'Restore Defender mock'
  $script:state.Defender.DisableRealtimeMonitoring=$true; $script:state.Protection.RealTimeProtectionEnabled=$false
  $r=Invoke-WmAction -Action DefenderEnable -Apply -BackupPath (Join-Path $temp 'def-enable.json')
  Assert $script:state.Protection.RealTimeProtectionEnabled 'Enable Defender mock'
  $bad=Join-Path $temp 'bad.json'
  foreach ($json in @('{', '{"Schema":1,"Machine":"other","Target":"Update","Exists":false,"Value":null}',
      '{"Schema":1,"Machine":"mock-machine","Target":"Service","Exists":true,"Value":1}',
      '{"Schema":1,"Machine":"mock-machine","Target":"Update","Exists":true,"Value":"1"}',
      '{"Schema":1,"Machine":"mock-machine","Target":"Defender","Exists":true,"Value":"false"}')) {
    [IO.File]::WriteAllText($bad,$json)
    Reject { Invoke-WmAction -Action Restore -RestorePath $bad -Apply } '.'
  }
  $count=$script:writes
  $script:reads=0
  function Get-WmState {
    $script:reads++
    if ($script:reads -eq 2) { $script:state.Managed=$true }
    return $script:state
  }
  Reject { Invoke-WmAction -Action UpdateDisable -Apply -BackupPath (Join-Path $temp 'race.json') } '未写入'
  Assert ($script:writes -eq $count) 'Policy race wrote state'
  function Get-WmState { return $script:state }
  $script:state.Managed=$false
  $script:ignored=$true
  Reject { Invoke-WmAction -Action UpdateDisable -Apply -BackupPath (Join-Path $temp 'ignored.json') } '部分完成'
  Assert (Test-Path (Join-Path $temp 'ignored.json')) 'Failure lost recovery backup'
  $script:ignored=$false; $script:failWrite=$true
  Reject { Invoke-WmAction -Action DefenderDisable -Apply -BackupPath (Join-Path $temp 'failed.json') } '部分完成'
  'PASS: Windows management defaults, dry-run, gates, validation, backup, restore and partial failure (mock only)'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }

# Exercise the real system-write adapter in a child scope with mocked primitives.
& {
  . $source -LibOnly
  $script:events=@(); $script:exists=$false
  function Test-Path { param($LiteralPath) return $script:exists }
  function New-Item { param($Path,[switch]$Force,$ErrorAction) $script:events+='create-key'; $script:exists=$true }
  function New-ItemProperty { param($LiteralPath,$Name,$PropertyType,$Value,[switch]$Force,$ErrorAction)
    Assert ($Name -eq 'NoAutoUpdate' -and $PropertyType -eq 'DWord' -and $Value -eq 1) 'Unexpected registry mutation'
    $script:events+='set-value'
  }
  function Get-Item { param($LiteralPath,$ErrorAction)
    $k=New-Object PSObject
    $k | Add-Member ScriptMethod GetValueNames { @('NoAutoUpdate','OtherValue') }
    return $k
  }
  function Remove-ItemProperty { param($LiteralPath,$Name,$ErrorAction)
    Assert ($Name -eq 'NoAutoUpdate') 'Restore touched another value'; $script:events+='remove-value'
  }
  function Set-MpPreference { param($DisableRealtimeMonitoring,$ErrorAction)
    Assert ($DisableRealtimeMonitoring -is [bool] -and -not $DisableRealtimeMonitoring) 'Defender enable mapping'
    $script:events+='defender-enable'
  }
  Set-WmValue Update @{Exists=$true;Value=1}
  Set-WmValue Update @{Exists=$false;Value=$null}
  Set-WmValue Defender @{Exists=$true;Value=$false}
  Assert (($script:events -join ',') -eq 'create-key,set-value,remove-value,defender-enable') 'Adapter sequence'
}
# Run the real policy detector against controlled inventory; failures must fail closed.
& {
  . $source -LibOnly
  $script:domain=$false; $script:policyPath=''; $script:probeFailure=$false
  function Get-CimInstance { param($ClassName,$ErrorAction) return @{PartOfDomain=$script:domain} }
  function Test-Path { param($LiteralPath)
    if ($script:probeFailure) { throw 'mock access denied' }
    return ($LiteralPath -eq $script:policyPath)
  }
  function Get-Item { param($LiteralPath,$ErrorAction) return @{SubKeyCount=1;ValueCount=0} }
  Assert (-not (Get-WmPolicyState).Managed) 'Clean machine blocked'
  $script:domain=$true
  Assert (Get-WmPolicyState).Managed 'Domain not detected'
  $script:domain=$false
  foreach ($path in @('HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo',
      'HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts',
      'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\History',
      'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender')) {
    $script:policyPath=$path
    Assert (Get-WmPolicyState).Managed "Policy not detected: $path"
  }
  $script:probeFailure=$true
  $r=Get-WmPolicyState
  Assert ($r.Managed -and $r.Issues.Count -gt 0) 'Detection errors must block writes'
}
# Windows launcher/integration checks execute only preflight rejection or installer dry-run.
if ([Environment]::OSVersion.Platform -eq 'Win32NT') {
  $engine=(Get-Process -Id $PID).Path
  $env:INST_NO_TTY='1'; $env:INST_NO_UPDATE_CHECK='1'
  $oldPath=[Environment]::GetEnvironmentVariable('Path','User')
  $output=& $engine -NoProfile -File (Join-Path $root 'install.ps1') -WindowsManagement -DryRun 2>&1 | Out-String
  Assert ($LASTEXITCODE -eq 0 -and $output -match 'winmanage.ps1' -and $output -match 'winmanage.cmd' -and $output -match 'winmanage.md') 'Installer forwarding dry-run'
  Assert ([Environment]::GetEnvironmentVariable('Path','User') -ceq $oldPath) 'Installer dry-run changed PATH'
  $savedPreference=$ErrorActionPreference; $ErrorActionPreference='Continue'
  try {
    $output=& cmd.exe /d /c ('"{0}" -Action DefenderUninstall' -f (Join-Path $root 'scripts/winmanage.cmd')) 2>&1 | Out-String
    $code=$LASTEXITCODE
  } finally { $ErrorActionPreference=$savedPreference }
  Assert ($code -ne 0) 'CMD failed to propagate unsupported action failure'
}
'PASS: primitive write adapters mocked; Windows launcher/installer checks conditional on Windows'
exit 0
