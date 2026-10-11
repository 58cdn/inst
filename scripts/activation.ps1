# inst Windows activation information. Never activates or downloads third-party scripts.
[CmdletBinding()]
param(
  [ValidateSet('Status','Settings','Troubleshoot','LicenseHelp','MasReference')]
  [string]$Action='Status',
  [switch]$Open, [switch]$DryRun, [switch]$LibOnly
)
$ErrorActionPreference='Stop'
function Get-ActivationLinks {
  return @{
    Settings='ms-settings:activation'
    Troubleshoot='https://support.microsoft.com/en-us/windows/activation/using-the-windows-activation-troubleshooter'
    LicenseHelp='https://support.microsoft.com/en-us/windows/activation/activate-windows'
    MasReference='https://github.com/massgravel/Microsoft-Activation-Scripts'
  }
}
function Assert-ActivationPlatform {
  if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw '状态查询和打开入口仅支持 Windows 10/11 客户端；其他平台可查看文档链接。' }
  $os=Get-CimInstance -ClassName Win32_OperatingSystem -Property Version,ProductType,BuildNumber -OperationTimeoutSec 15 -ErrorAction Stop
  if ($os.ProductType -ne 1 -or $os.Version -notmatch '^10\.0\.' -or [int]$os.BuildNumber -lt 10240) { throw '仅支持 Windows 10/11 客户端，不支持 Server 或旧版。' }
}
function Read-ActivationProducts {
  # Query only Windows licensing records with installed keys; never retrieve key values.
  Get-CimInstance -ClassName SoftwareLicensingProduct -Namespace root/cimv2 -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -Property Name,LicenseStatus -OperationTimeoutSec 15 -ErrorAction Stop
}
function ConvertTo-ActivationStatus($Products) {
  $labels=@{0='Unlicensed';1='Licensed';2='OOBGrace';3='OOTGrace';4='NonGenuineGrace';5='Notification';6='ExtendedGrace'}
  $rows=@(foreach ($p in $Products) {
    $number=0
    $known=$null -ne $p.LicenseStatus -and [int]::TryParse([string]$p.LicenseStatus,[ref]$number) -and $labels.ContainsKey($number)
    [pscustomobject]@{ Product=[string]$p.Name; Status=$(if ($known) {$labels[$number]} else {'Unknown'}); Code=$(if ($known) {$number} else {$null}) }
  })
  [pscustomobject]@{
    Result=$(if (-not $rows.Count -or @($rows | Where-Object Status -eq 'Unknown').Count) {'Unknown'} else {'Queried'})
    Products=$rows
    Notice='仅为 Windows 软件许可服务报告的技术状态，不证明正版许可或永久激活；多条记录不合并推断。Office 状态不在本模块查询范围。'
  }
}
function Open-ActivationLink([string]$Uri) {
  # Fixed allowlist only; no custom URL, command, download, credentials or elevation.
  if (@((Get-ActivationLinks).Values) -notcontains $Uri) { throw '入口不在允许列表。' }
  Start-Process -FilePath $Uri -ErrorAction Stop | Out-Null
}
function Invoke-ActivationAction {
  param([string]$Action='Status',[switch]$Open,[switch]$DryRun)
  if ($Action -notin @('Status','Settings','Troubleshoot','LicenseHelp','MasReference')) { throw '未知操作。' }
  if ($Action -eq 'Status') {
    if ($Open) { throw 'Status 不接受 -Open；请显式选择一个入口。' }
    if ($DryRun) { return [pscustomobject]@{Result='Preview';Action='Status';Notice='将只读查询 Windows 激活状态，不执行激活。'} }
    Assert-ActivationPlatform
    return ConvertTo-ActivationStatus @(Read-ActivationProducts)
  }
  $uri=(Get-ActivationLinks)[$Action]
  $notice=if ($Action -eq 'MasReference') {
    '第三方 MAS 项目参考，非微软官方许可渠道。HWID / Ohook 为项目方法名称；本工具不下载、不执行脚本。打开网页不表示已激活，激活不等于获得正版许可。'
  } else { '微软官方入口；需已有有效许可证。打开设置或网页不表示已激活，后续操作由用户自行选择。' }
  $result='Reference'
  if ($Open -and -not $DryRun) {
    Assert-ActivationPlatform
    Open-ActivationLink $uri
    $result='OpenRequested'
  } elseif ($DryRun) { $result='Preview' }
  [pscustomobject]@{Result=$result;Action=$Action;Uri=$uri;Notice=$notice}
}
if ($LibOnly) { return }
try {
  $result=Invoke-ActivationAction -Action $Action -Open:$Open -DryRun:$DryRun
  $result | ConvertTo-Json -Depth 5
  if ($result.Result -eq 'Unknown') { exit 2 }
} catch { Write-Error -ErrorAction Continue $_; exit 1 }
