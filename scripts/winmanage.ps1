# Windows 10/11 management. No writes without -Apply; -DryRun always wins.
[CmdletBinding()]
param(
  [ValidateSet('Status','UpdateDisable','UpdateEnable','DefenderDisable','DefenderEnable','Restore','DefenderUninstall','SecurityCenterDisable')]
  [string]$Action = 'Status',
  [switch]$Apply, [switch]$DryRun,
  [string]$BackupPath, [string]$RestorePath,
  [switch]$LibOnly
)
$ErrorActionPreference = 'Stop'
$script:UpdateKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'

function Get-WmUpdateValue {
  if (-not (Test-Path -LiteralPath $script:UpdateKey)) { return @{ Exists=$false; Value=$null } }
  $key = Get-Item -LiteralPath $script:UpdateKey
  if ($key.GetValueNames() -notcontains 'NoAutoUpdate') { return @{ Exists=$false; Value=$null } }
  if ($key.GetValueKind('NoAutoUpdate') -ne 'DWord') { throw 'NoAutoUpdate 类型异常；拒绝覆盖。' }
  $value = $key.GetValue('NoAutoUpdate')
  if ($value -notin @(0,1)) { throw 'NoAutoUpdate 值异常；拒绝覆盖。' }
  return @{ Exists=$true; Value=[int]$value }
}

function Get-WmPolicyState {
  $issues = @(); $managed = $false
  try {
    $domain = (Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).PartOfDomain
    if ($domain -isnot [bool]) { throw '无法确定域管理状态' }
    $managed = $domain
    # Conservative: domain/Entra join, MDM enrollment, or policy provenance blocks local writes.
    foreach ($p in @('HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo',
        'HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows Advanced Threat Protection',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Group Policy\History',
        'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender')) {
      if (Test-Path -LiteralPath $p) {
        $key = Get-Item -LiteralPath $p -ErrorAction Stop
        if ($key.SubKeyCount -gt 0 -or $key.ValueCount -gt 0) { $managed = $true }
      }
    }
    $wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    if (Test-Path -LiteralPath $wu) {
      $k = Get-Item -LiteralPath $wu -ErrorAction Stop
      if ($k.ValueCount -gt 0 -or @($k.GetSubKeyNames() | Where-Object { $_ -ne 'AU' }).Count) { $managed=$true }
    }
    if (Test-Path -LiteralPath $script:UpdateKey) {
      $k = Get-Item -LiteralPath $script:UpdateKey -ErrorAction Stop
      if (@($k.GetValueNames() | Where-Object { $_ -ne 'NoAutoUpdate' }).Count) { $managed=$true }
    }
  } catch { $issues += "管理策略检测失败: $_"; $managed=$true }
  [pscustomobject]@{ Managed=$managed; Issues=$issues }
}

function Get-WmState {
  if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw '仅支持 Windows 10/11 客户端。' }
  $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
  $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $admin = (New-Object Security.Principal.WindowsPrincipal($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  $policy=Get-WmPolicyState
  $issues=@($policy.Issues); $managed=$policy.Managed
  $mp = $null; $pref = $null; $update = $null
  try { $update=Get-WmUpdateValue } catch { $issues += "更新策略读取失败: $_" }
  try {
    $mp=Get-MpComputerStatus -ErrorAction Stop | Select-Object IsTamperProtected, AMRunningMode, RealTimeProtectionEnabled, AntivirusEnabled, AMServiceEnabled
    $pref=Get-MpPreference -ErrorAction Stop | Select-Object DisableRealtimeMonitoring
  } catch { $issues += "Defender 查询不可用: $_" }
  $services=@(); $antivirus=@()
  try { $services=@(Get-Service -Name wuauserv,WinDefend,wscsvc,SecurityHealthService -ErrorAction Stop | Select-Object Name,Status,StartType) } catch { $issues += "服务查询不完整: $_" }
  try { $antivirus=@(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntivirusProduct -ErrorAction Stop | Select-Object displayName) } catch { $issues += "安全中心产品查询失败: $_" }
  $machine=(Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography' -ErrorAction Stop).MachineGuid
  [pscustomobject]@{
    Machine=$machine; Build=[int]$os.BuildNumber; ProductType=[int]$os.ProductType
    Edition=[string]$cv.EditionID; OSVersion=[string]$os.Version; Admin=$admin; Managed=$managed
    Services=$services; AntivirusProducts=$antivirus; QueryComplete=($issues.Count -eq 0)
    Update=$update; Defender=$pref; Protection=$mp; Issues=$issues
  }
}

function Assert-WmAllowed($State, [string]$Target) {
  if (-not $State.Machine -or $State.Machine -isnot [string]) { throw '无法确定本机标识；不能创建可恢复的备份。' }
  if ($State.ProductType -ne 1 -or $State.Build -lt 10240 -or $State.OSVersion -notmatch '^10\.0\.') { throw '仅支持 Windows 10/11 客户端；Server/旧版不支持。' }
  if (-not [Environment]::Is64BitProcess -and [Environment]::Is64BitOperatingSystem) { throw '请使用 64 位 PowerShell。' }
  if (-not $State.Admin) { throw '需要管理员 PowerShell；不会自动提权。' }
  if ($State.Managed) { throw '检测到组织管理/已有策略或检测失败，请由管理员在原管理渠道操作。' }
  if ($Target -eq 'Update') {
    if ($State.Edition -notin @('Professional','ProfessionalN','Enterprise','EnterpriseN','Education','EducationN','ProfessionalEducation','ProfessionalWorkstation','EnterpriseS','EnterpriseSN')) {
      throw '此版本不在自动更新策略支持白名单；Home/未知版本请使用 Windows 设置暂停或恢复更新。'
    }
    if ($null -eq $State.Update) { throw '无法读取更新原值。' }
  } else {
    if ($null -eq $State.Defender -or $null -eq $State.Protection) { throw 'Defender 不可用；未执行修改。' }
    if ($State.Protection.IsTamperProtected -ne $false) { throw '篡改防护启用或状态未知；拒绝修改，不绕过防护。' }
    if ($State.Protection.AMRunningMode -ne 'Normal') { throw 'Defender 非正常主动模式（可能有第三方杀毒软件）；请在原管理渠道处理。' }
    if ($State.Defender.DisableRealtimeMonitoring -isnot [bool]) { throw 'Defender 原值未知。' }
  }
}

function Read-WmBackup([string]$Path, $State) {
  if (-not $Path) { throw 'Restore 需要 -RestorePath。' }
  $b = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  if (($b.Schema -isnot [int] -and $b.Schema -isnot [long]) -or $b.Schema -ne 1 -or $b.Machine -isnot [string] -or -not $b.Machine -or $b.Machine -cne $State.Machine -or $b.Target -notin @('Update','Defender')) { throw '备份版本、设备或目标不匹配。' }
  if ($b.Exists -isnot [bool]) { throw '备份 Exists 类型无效。' }
  if ($b.Target -eq 'Update') {
    if ($b.Exists -and ($b.Value -isnot [long] -and $b.Value -isnot [int])) { throw '备份更新值类型无效。' }
    if ($b.Exists -and $b.Value -notin @(0,1)) { throw '备份更新值无效。' }
    if (-not $b.Exists -and $null -ne $b.Value) { throw '不存在的更新值必须为 null。' }
  } elseif (-not $b.Exists -or $b.Value -isnot [bool]) { throw '备份 Defender 值无效。' }
  return $b
}

function Save-WmBackup([string]$Path, $Snapshot) {
  if (-not $Path) { throw '写入前必须指定新的 -BackupPath（不会覆盖已有文件）。' }
  $full = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
  $bytes = [Text.Encoding]::UTF8.GetBytes(($Snapshot | ConvertTo-Json -Depth 5))
  $stream = [IO.File]::Open($full, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
  try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush() } finally { $stream.Dispose() }
  # Read back before any system mutation; incomplete backup blocks the operation.
  $saved=Get-Content -LiteralPath $full -Raw | ConvertFrom-Json
  if ($saved.Machine -cne $Snapshot.Machine -or $saved.Target -ne $Snapshot.Target -or
      $saved.Exists -ne $Snapshot.Exists -or $saved.Value -cne $Snapshot.Value) { throw '备份验证失败。' }
  return $full
}

function Set-WmValue([string]$Target, $Value) {
  if ($Target -eq 'Update') {
    if ($Value.Exists) {
      if (-not (Test-Path -LiteralPath $script:UpdateKey)) { New-Item -Path $script:UpdateKey -Force -ErrorAction Stop | Out-Null }
      New-ItemProperty -LiteralPath $script:UpdateKey -Name NoAutoUpdate -PropertyType DWord -Value $Value.Value -Force -ErrorAction Stop | Out-Null
    } elseif (Test-Path -LiteralPath $script:UpdateKey) {
      $key = Get-Item -LiteralPath $script:UpdateKey -ErrorAction Stop
      if ($key.GetValueNames() -contains 'NoAutoUpdate') { Remove-ItemProperty -LiteralPath $script:UpdateKey -Name NoAutoUpdate -ErrorAction Stop }
    }
  } else { Set-MpPreference -DisableRealtimeMonitoring ([bool]$Value.Value) -ErrorAction Stop }
}

function Test-WmValue([string]$Target, $Expected) {
  if ($Target -eq 'Update') {
    $v=Get-WmUpdateValue
    return ($v.Exists -eq $Expected.Exists -and $v.Value -ceq $Expected.Value)
  }
  $pref=Get-MpPreference -ErrorAction Stop
  $status=Get-MpComputerStatus -ErrorAction Stop
  return ($pref.DisableRealtimeMonitoring -eq $Expected.Value -and $status.RealTimeProtectionEnabled -eq (-not $Expected.Value))
}

function Invoke-WmAction {
  param([string]$Action='Status', [switch]$Apply, [switch]$DryRun, [string]$BackupPath, [string]$RestorePath)
  if ($Action -notin @('Status','UpdateDisable','UpdateEnable','DefenderDisable','DefenderEnable','Restore','DefenderUninstall','SecurityCenterDisable')) { throw '未知操作。' }
  if ($Action -in @('DefenderUninstall','SecurityCenterDisable')) {
    throw '不支持卸载 Windows 10/11 内置 Defender 或关闭/隐藏安全中心；安全中心界面不是防护引擎。第三方杀毒请使用厂商官方卸载程序。'
  }
  $state=Get-WmState
  if ($Action -eq 'Status') { return $state }
  if ($Action -eq 'Restore') {
    $desired=Read-WmBackup $RestorePath $state
    $target=$desired.Target
  } else {
    $target=if ($Action -like 'Update*') { 'Update' } else { 'Defender' }
    $v=($Action -like '*Disable')
    if ($target -eq 'Update') { $v=[int]$v }
    $desired=@{ Exists=$true; Value=$v }
  }
  Assert-WmAllowed $state $target
  $warning=if ($target -eq 'Update') { '仅更改自动更新策略；不停止服务，不保证永久禁更，手动更新仍可用。' } else { '仅更改实时保护；关闭会降低安全性，Windows 可能自动重新启用；不是卸载或关闭所有防护。' }
  if (-not $Apply -or $DryRun) { return [pscustomobject]@{ Result='Preview'; Target=$target; Exists=$desired.Exists; Value=$desired.Value; Warning=$warning; Writes=0 } }
  $original=if ($target -eq 'Update') { $state.Update } else { @{ Exists=$true; Value=$state.Defender.DisableRealtimeMonitoring } }
  $snapshot=[ordered]@{ Schema=1; Machine=$state.Machine; Target=$target; Exists=$original.Exists; Value=$original.Value; CreatedUtc=[DateTime]::UtcNow.ToString('o') }
  $backup=Save-WmBackup $BackupPath $snapshot
  try {
    # Recheck immediately before write to catch policy/protection changes after backup.
    $fresh=Get-WmState
    Assert-WmAllowed $fresh $target
    $now=if ($target -eq 'Update') { $fresh.Update } else { @{ Exists=$true; Value=$fresh.Defender.DisableRealtimeMonitoring } }
    if ($now.Exists -ne $original.Exists -or $now.Value -cne $original.Value) { throw '原值已变化；请重新查询并生成新备份。' }
  } catch { throw "未写入；备份保留在 $backup。$_" }
  try {
    Set-WmValue $target $desired
    if (-not (Test-WmValue $target $desired)) { throw '读取结果与期望不一致，可能被策略/防护阻止或尚未生效。' }
  } catch {
    # Do not overwrite a concurrent policy change by automatically rolling back.
    throw "失败或部分完成，不能确认目标生效。备份: $backup；查询状态后用 Restore 显式回滚。原因: $_"
  }
  [pscustomobject]@{ Result='Verified'; Target=$target; Backup=$backup; Warning=$warning }
}
if ($LibOnly) { return }
try { Invoke-WmAction -Action $Action -Apply:$Apply -DryRun:$DryRun -BackupPath $BackupPath -RestorePath $RestorePath | ConvertTo-Json -Depth 6 }
catch { Write-Error -ErrorAction Continue $_; exit 1 }
