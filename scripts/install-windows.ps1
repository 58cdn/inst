# inst: Windows PowerShell 5.1+ / PowerShell 7 安装器主实现。
# install.ps1 / install.cmd / install.sh 都会以 powershell -File 子进程运行本文件；-LibOnly 仅导入函数供测试使用。
[CmdletBinding(PositionalBinding = $false)]
param(
  [switch]$All, [switch]$Node, [switch]$Python, [switch]$Mirrors, [switch]$Agents, [switch]$Desktop,
  [switch]$Check, [switch]$Update, [switch]$SelfUpdate, [switch]$InstallShortcut, [switch]$Menu,
  [switch]$DryRun, [switch]$Yes, [switch]$Quiet, [switch]$Version, [switch]$Help, [switch]$LibOnly,
  [switch]$OfficialAgents, [switch]$ApplySystemMirror,
  [string]$AgentList, [string]$AgentMethod, [string]$AgentPackages,
  [string]$Endpoint, [string]$BaseUrl, [string]$Model,
  [string]$AgentApiUrl, [string]$AnthropicBaseUrl, [string]$OpenAiBaseUrl,
  [string]$Region, [string]$MirrorPreset, [string]$NpmRegistry, [string]$PipIndex, [string]$SystemMirror, [string]$GhProxy,
  [string]$Prefix, [string]$PythonVersion,
  [string]$DesktopApps, [string]$DesktopDir, [string]$ClaudeDesktopUrl, [string]$CodexDesktopUrl,
  [string]$ClaudeDesktopArgs
)

$InstVersion = '1.0.0'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }

function Get-Default([string]$Value, [string]$EnvName, [string]$Fallback) {
  if ($Value) { return $Value }
  $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
  if ($fromEnv) { return $fromEnv }
  return $Fallback
}
$InstBase = Get-Default '' 'INST_RAW_BASE_URL' 'https://inst.linux.yun'
$Prefix = Get-Default $Prefix 'INST_PREFIX' (Join-Path $env:LOCALAPPDATA 'inst')
$PythonVersion = Get-Default $PythonVersion 'INST_PYTHON_VERSION' 'latest'
$Region = Get-Default $Region 'INST_REGION' 'auto'
$MirrorPreset = Get-Default $MirrorPreset 'INST_MIRROR_PRESET' ''
$NpmRegistry = Get-Default $NpmRegistry 'INST_NPM_REGISTRY' ''
$PipIndex = Get-Default $PipIndex 'INST_PIP_INDEX' ''
$SystemMirror = Get-Default $SystemMirror 'INST_SYSTEM_MIRROR' ''
$GhProxy = Get-Default $GhProxy 'INST_GH_PROXY' ''
$AgentList = Get-Default $AgentList 'INST_AGENTS' ''
$AgentMethod = Get-Default $AgentMethod 'INST_AGENT_METHOD' 'auto'
$AgentPackages = Get-Default $AgentPackages 'INST_AGENT_PACKAGES' ''
$DesktopApps = Get-Default $DesktopApps 'INST_DESKTOP_APPS' 'claude,codex'
$DesktopDir = Get-Default $DesktopDir 'INST_DESKTOP_DIR' ''
$ClaudeDesktopUrl = Get-Default $ClaudeDesktopUrl 'INST_DESKTOP_CLAUDE_URL' ''
$CodexDesktopUrl = Get-Default $CodexDesktopUrl 'INST_DESKTOP_CODEX_URL' ''
$Endpoint = Get-Default $Endpoint 'INST_ENDPOINT_AGENTS' ''
$BaseUrl = Get-Default $BaseUrl 'INST_BASE_URL' (Get-Default $AgentApiUrl 'INST_AGENT_API_URL' '')
$AnthropicBaseUrl = Get-Default $AnthropicBaseUrl 'INST_ANTHROPIC_BASE_URL' ''
$OpenAiBaseUrl = Get-Default $OpenAiBaseUrl 'INST_OPENAI_BASE_URL' ''
$Model = Get-Default $Model 'INST_MODEL' ''
$ApiKey = Get-Default '' 'INST_API_KEY' ''
$DefaultAgents = 'claude,codex,gemini,opencode'
$ShortcutDir = Join-Path $env:LOCALAPPDATA 'inst'
$ShortcutScript = Join-Path $ShortcutDir 'inst.ps1'
$ShortcutBin = Join-Path $ShortcutDir 'bin'
$Interactive = $false
$IsRemote = ($env:INST_RUN_MODE -eq 'remote')
$Arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64' -or $env:PROCESSOR_ARCHITEW6432 -eq 'ARM64') { 'arm64' } elseif ([Environment]::Is64BitOperatingSystem) { 'x64' } else { 'x86' }

# ---------------------------------------------------------------- 输出与交互
function Write-Inst([string]$Message) { if (-not $Quiet) { Write-Host '[inst] ' -ForegroundColor Cyan -NoNewline; Write-Host $Message } }
function Write-Ok([string]$Message) { if (-not $Quiet) { Write-Host '[ ok ] ' -ForegroundColor Green -NoNewline; Write-Host $Message } }
function Write-Warn([string]$Message) { Write-Host '[warn] ' -ForegroundColor Yellow -NoNewline; Write-Host $Message }
function Write-Fail([string]$Message) { Write-Host '[fail] ' -ForegroundColor Red -NoNewline; Write-Host $Message }
function Write-Step([string]$Message) { if (-not $Quiet) { Write-Host ''; Write-Host "==> $Message" -ForegroundColor White } }
function Write-Plan([string]$Message) { Write-Host "+ $Message" -ForegroundColor Yellow }
function Read-Choice([string]$Prompt, [string]$Default = '') {
  $label = if ($Default) { "$Prompt [$Default]" } else { $Prompt }
  $reply = Read-Host $label
  if ([string]::IsNullOrWhiteSpace($reply)) { return $Default }
  return $reply.Trim()
}
function Confirm-Inst([string]$Prompt, [string]$Default = 'n') {
  if ($Yes) { return $true }
  if (-not $Interactive) { return $false }
  return ((Read-Choice "$Prompt (y/N)" $Default) -match '^(y|yes)$')
}
function Wait-Inst { if ($Interactive) { [void](Read-Host '按回车键继续') } }

function Assert-HttpsUrl([string]$Value, [string]$Name) {
  $uri = $null
  if (-not [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -or $uri.Scheme -ne 'https' -or -not $uri.Host) {
    throw "$Name 必须是 HTTPS URL"
  }
}
function Invoke-NodeCommand([string]$Executable, [string[]]$Arguments) {
  & $Executable @Arguments
  if ($LASTEXITCODE -ne 0) { throw "$Executable $Arguments 失败，退出码 $LASTEXITCODE" }
}
function Invoke-Native([string]$Executable, [string[]]$Arguments) {
  if ($DryRun) { Write-Plan "$Executable $($Arguments -join ' ')"; return }
  Invoke-NodeCommand $Executable $Arguments
}
function Invoke-NativeCapture([string]$Executable, [string[]]$Arguments) {
  $output = @(& $Executable @Arguments)
  if ($LASTEXITCODE -ne 0) { throw "$Executable $($Arguments -join ' ') 失败，退出码 $LASTEXITCODE" }
  return $output
}
function Invoke-CheckedProcess([string]$FilePath, [string]$ArgumentString, [string]$Description, [switch]$Visible) {
  if ($DryRun) { Write-Plan "$Description ($FilePath $ArgumentString)"; return }
  $params = @{ FilePath = $FilePath; Wait = $true; PassThru = $true }
  if ($ArgumentString) { $params.ArgumentList = $ArgumentString }
  if (-not $Visible) { $params.WindowStyle = 'Hidden' }
  $process = Start-Process @params
  if ($process.ExitCode -ne 0) { throw "$Description 失败，退出码 $($process.ExitCode)" }
}
function Test-Admin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  return (New-Object Security.Principal.WindowsPrincipal $identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Compare-InstVersion([string]$A, [string]$B) {
  try { return ([version]$A).CompareTo([version]$B) } catch { return 0 }
}

# ---------------------------------------------------------------- 环境变量
function Refresh-ProcessEnvironment {
  foreach ($name in @('NVM_HOME','NVM_SYMLINK','PYENV','PYENV_ROOT','PYENV_HOME')) {
    $value = [Environment]::GetEnvironmentVariable($name, 'User')
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable($name, 'Machine') }
    if ($value) { Set-Item -Path "Env:$name" -Value $value }
  }
  $paths = @($env:Path, [Environment]::GetEnvironmentVariable('Path','User'), [Environment]::GetEnvironmentVariable('Path','Machine'))
  $env:Path = (($paths -join ';') -split ';' | Where-Object { $_ } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) } | Select-Object -Unique) -join ';'
}
function Add-UserPath([string]$Path, [switch]$Force) {
  if ($DryRun) { Write-Plan "用户 PATH 添加 $Path"; return }
  if (-not $Force -and -not (Test-Path -LiteralPath $Path)) { return }
  $current = [Environment]::GetEnvironmentVariable('Path','User')
  $parts = @($current -split ';' | Where-Object { $_ })
  if ($parts -notcontains $Path -and $parts -notcontains ($Path.TrimEnd('\'))) {
    [Environment]::SetEnvironmentVariable('Path', ((@($Path) + $parts) -join ';'), 'User')
  }
  if (($env:Path -split ';') -notcontains $Path) { $env:Path = "$Path;$env:Path" }
}
function Set-UserEnv([string]$Name, [string]$Value) {
  if ($DryRun) { if ($Value) { Write-Plan "设置用户环境变量 $Name" } else { Write-Plan "删除用户环境变量 $Name" }; return }
  if ($Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value, 'User'); Set-Item -Path "Env:$Name" -Value $Value
  } else {
    [Environment]::SetEnvironmentVariable($Name, $null, 'User'); Remove-Item -Path "Env:$Name" -ErrorAction SilentlyContinue
  }
}
function Write-Utf8File([string]$Path, [string]$Text) {
  $dir = Split-Path -Parent $Path
  if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  # 无 BOM：node 的 JSON.parse 不接受 BOM。
  [IO.File]::WriteAllText($Path, $Text, (New-Object Text.UTF8Encoding $false))
}

# ---------------------------------------------------------------- 区域与镜像预设
$script:RegionResolved = $null
function Get-InstRegion {
  if ($script:RegionResolved) { return $script:RegionResolved }
  $resolved = $Region
  if ($resolved -eq 'auto') {
    $country = ''
    try { $country = ([string](Invoke-RestMethod -Uri 'https://ipinfo.io/country' -TimeoutSec 3 -UseBasicParsing)).Trim() } catch { }
    if (-not $country) {
      try { Invoke-WebRequest -Uri 'https://www.google.com' -Method Head -TimeoutSec 3 -UseBasicParsing | Out-Null; $country = 'XX' } catch { $country = 'CN' }
    }
    $resolved = if ($country -eq 'CN') { 'cn' } else { 'global' }
  }
  $script:RegionResolved = $resolved
  return $resolved
}
function Get-PresetPip([string]$Preset) {
  switch ($Preset) {
    'tuna' { 'https://pypi.tuna.tsinghua.edu.cn/simple' }
    'aliyun' { 'https://mirrors.aliyun.com/pypi/simple/' }
    'ustc' { 'https://mirrors.ustc.edu.cn/pypi/simple' }
    'tencent' { 'https://mirrors.cloud.tencent.com/pypi/simple' }
    'huawei' { 'https://repo.huaweicloud.com/repository/pypi/simple' }
    'official' { 'https://pypi.org/simple' }
    default { '' }
  }
}
function Get-PresetNpm([string]$Preset) {
  switch ($Preset) {
    'tencent' { 'https://mirrors.cloud.tencent.com/npm/' }
    'huawei' { 'https://repo.huaweicloud.com/repository/npm/' }
    'official' { 'https://registry.npmjs.org/' }
    default { 'https://registry.npmmirror.com' }
  }
}
function Get-PresetConda([string]$Preset) {
  switch ($Preset) {
    'ustc' { 'https://mirrors.ustc.edu.cn/anaconda' }
    'aliyun' { 'https://mirrors.aliyun.com/anaconda' }
    'official' { '' }
    default { 'https://mirrors.tuna.tsinghua.edu.cn/anaconda' }
  }
}
$NodeMirrorCn = 'https://cdn.npmmirror.com/binaries/node/'
$NodeMirrorOfficial = 'https://nodejs.org/dist/'
$NpmMirrorCn = 'https://npmmirror.com/mirrors/npm/'
# pyenv-win 的 pyenv update 需要解析 python.org 风格的 HTML 目录，npmmirror 返回 JSON，因此用华为云。
$PythonMirrorCn = 'https://mirrors.huaweicloud.com/python'
function Resolve-GhUrl([string]$Url) {
  if ($GhProxy -and $Url -match '^https://(github\.com|raw\.githubusercontent\.com|objects\.githubusercontent\.com)/') { return ($GhProxy.TrimEnd('/') + '/' + $Url) }
  return $Url
}

# ---------------------------------------------------------------- 下载
function Save-Download([string]$Url, [string]$OutFile) {
  Assert-HttpsUrl $Url '下载地址'
  if ($DryRun) { Write-Plan "下载 $Url -> $OutFile"; return }
  $dir = Split-Path -Parent $OutFile
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  Write-Inst "下载 $Url"
  $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($curl) {
    & $curl.Source --proto '=https' --proto-redir '=https' -fL --retry 2 --connect-timeout 20 -o $OutFile $Url
    if ($LASTEXITCODE -ne 0) { Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue; throw "下载失败 ($LASTEXITCODE): $Url" }
  } else {
    Invoke-WebRequest -UseBasicParsing -Uri $Url -OutFile $OutFile
  }
}
function Invoke-OfficialPs1([string]$Url, [string[]]$ScriptArgs = @()) {
  Assert-HttpsUrl $Url '官方安装脚本'
  if ($DryRun) { Write-Plan "下载并执行 $Url $($ScriptArgs -join ' ')"; return }
  # 在子进程中执行，避免官方脚本的 exit 关闭当前窗口。参数只来自内置表，不含用户输入。
  $command = "`$ProgressPreference='SilentlyContinue'; [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; & ([scriptblock]::Create((Invoke-RestMethod -UseBasicParsing '$Url'))) $($ScriptArgs -join ' ')"
  & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command $command
  if ($LASTEXITCODE -ne 0) { throw "官方安装脚本失败 ($LASTEXITCODE): $Url" }
  Refresh-ProcessEnvironment
}

# ---------------------------------------------------------------- Node.js
function Get-NpmCommand {
  $npm = Get-Command npm.cmd -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($npm) { return $npm.Source }
  return $null
}
function Invoke-NpmGlobal([string[]]$Packages) {
  $npm = Get-NpmCommand
  if (-not $npm -and -not $DryRun) { throw 'npm 不可用，请先安装 Node.js（菜单 1 或 -Node）' }
  if (-not $npm) { $npm = 'npm.cmd' }
  $arguments = @('install','--global') + $Packages
  if ($NpmRegistry) { $arguments += @('--registry', $NpmRegistry) }
  Invoke-Native $npm $arguments
}
function Find-Nvm {
  Refresh-ProcessEnvironment
  $candidates = @()
  if ($env:NVM_HOME) { $candidates += $env:NVM_HOME }
  $candidates += @((Join-Path $env:LOCALAPPDATA 'nvm'), (Join-Path $env:APPDATA 'nvm'))
  foreach ($candidate in $candidates) {
    $exe = Join-Path $candidate 'nvm.exe'
    if (Test-Path -LiteralPath $exe) { return $exe }
  }
  $command = Get-Command nvm.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($command) { return $command.Source }
  return $null
}
function Set-NvmMirrors([string]$NvmExe, [bool]$Enabled) {
  if ($DryRun) { Write-Plan "nvm node_mirror/npm_mirror -> $(if ($Enabled) { $NodeMirrorCn } else { '官方' })"; return }
  $nvmHome = Split-Path -Parent $NvmExe
  $version = [string](@(& $NvmExe version 2>$null) | Select-Object -First 1)
  if ($version -match '^\s*v?2\.') {
    # nvm-windows 2.x 把设置存入注册表，支持逗号分隔的回退列表
    $node = if ($Enabled) { "$($NodeMirrorCn.TrimEnd('/')),https://nodejs.org/dist" } else { 'https://nodejs.org/dist' }
    $npm = if ($Enabled) { 'https://registry.npmmirror.com,https://registry.npmjs.org' } else { 'https://registry.npmjs.org' }
    try { Invoke-NodeCommand $NvmExe @('config','set',"node_mirror=$node"); Invoke-NodeCommand $NvmExe @('config','set',"npm_mirror=$npm") }
    catch { Write-Warn "nvm 2.x 镜像设置失败: $_" }
    return
  }
  Set-NvmSetting $nvmHome 'node_mirror' $(if ($Enabled) { $NodeMirrorCn } else { '' })
  Set-NvmSetting $nvmHome 'npm_mirror' $(if ($Enabled) { $NpmMirrorCn } else { '' })
}
function Set-NvmSetting([string]$NvmHome, [string]$Key, [string]$Value) {
  $settings = Join-Path $NvmHome 'settings.txt'
  $lines = @()
  if (Test-Path -LiteralPath $settings) { $lines = @(Get-Content -LiteralPath $settings | Where-Object { $_ -notmatch "^$([regex]::Escape($Key)):" }) }
  if ($Value) { $lines += "${Key}: $Value" }
  Write-Utf8File $settings (($lines -join "`r`n") + "`r`n")
}
function Get-NvmNodeMirror([string]$NvmExe) {
  $settings = Join-Path (Split-Path -Parent $NvmExe) 'settings.txt'
  if (Test-Path -LiteralPath $settings) {
    foreach ($line in Get-Content -LiteralPath $settings) {
      if ($line -match '^node_mirror:\s*(.+)$') { return $Matches[1].Trim() }
    }
  }
  return ''
}
function Test-NodeAssetUrl([string]$Url) {
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Method Head -Uri $Url -TimeoutSec 10 -ErrorAction Stop
    return ([int]$response.StatusCode -ge 200 -and [int]$response.StatusCode -lt 400)
  } catch {
    return $false
  }
}
function Get-NodeLtsCandidatesFromCatalog([object[]]$Catalog, [string]$Mirror) {
  $platform = switch ($Arch) {
    'arm64' { 'win-arm64' }
    'x86' { 'win-x86' }
    default { 'win-x64' }
  }
  $base = $Mirror.TrimEnd('/') + '/'
  $releases = @(
    foreach ($release in $Catalog) {
      $raw = [string]$release.version
      $version = $raw.TrimStart('v')
      if ($version -notmatch '^\d+\.\d+\.\d+$' -or -not $release.lts) { continue }
      if (@($release.files) -notcontains "$platform-zip") { continue }
      [pscustomobject]@{
        Version = $version
        Url = ($base + "v$version/node-v$version-$platform.zip")
      }
    }
  ) | Sort-Object { [version]$_.Version } -Descending
  # Bound retries per mirror; older supported LTS patch versions remain fallback choices.
  return @($releases | Select-Object -First 4)
}
function Get-NodeLtsVersionFromCatalog([object[]]$Catalog, [string]$Mirror) {
  foreach ($release in @(Get-NodeLtsCandidatesFromCatalog $Catalog $Mirror)) {
    if (Test-NodeAssetUrl $release.Url) { return $release }
  }
  return $null
}
function Resolve-NodeLtsVersion([string]$NvmExe, [bool]$Cn) {
  $mirrors = @()
  if ($Cn) { $mirrors += $NodeMirrorCn }
  $configured = Get-NvmNodeMirror $NvmExe
  if ($configured) { $mirrors += $configured }
  $mirrors += $NodeMirrorOfficial
  $mirrors = @($mirrors | ForEach-Object { $_.TrimEnd('/') + '/' } | Select-Object -Unique)
  foreach ($mirror in $mirrors) {
    try {
      $catalog = Invoke-RestMethod -Uri ($mirror + 'index.json') -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
    } catch {
      Write-Warn "Node.js 版本列表不可用: $mirror"
      continue
    }
    $candidate = Get-NodeLtsVersionFromCatalog $catalog $mirror
    if ($candidate) {
      return [pscustomobject]@{ Version = $candidate.Version; Mirror = $mirror }
    }
    Write-Warn "Node.js LTS 索引中的 Windows 安装包尚未同步: $mirror"
  }
  return $null
}
function Set-NvmNodeMirror([string]$NvmExe, [string]$Mirror) {
  $nvmHome = Split-Path -Parent $NvmExe
  $version = [string](@(& $NvmExe version 2>$null) | Select-Object -First 1)
  if ($version -match '^\s*v?2\.') {
    Invoke-NodeCommand $NvmExe @('config','set',"node_mirror=$($Mirror.TrimEnd('/'))")
  } else {
    Set-NvmSetting $nvmHome 'node_mirror' $Mirror
  }
}
function Resolve-NodeInstallTarget([string]$NvmExe, [bool]$Cn) {
  $candidate = Resolve-NodeLtsVersion $NvmExe $Cn
  if ($candidate) {
    $activeMirror = Get-NvmNodeMirror $NvmExe
    if (-not $activeMirror -or $activeMirror.TrimEnd('/') -ne $candidate.Mirror.TrimEnd('/')) {
      try { Set-NvmNodeMirror $NvmExe $candidate.Mirror }
      catch { throw "无法配置 Node.js 下载镜像 $($candidate.Mirror): $_" }
    }
    Write-Inst "选择 Node.js LTS $($candidate.Version)"
    return $candidate.Version
  }
  Write-Warn '无法预先验证 Node.js LTS 安装包，将交给 nvm 直接解析 lts'
  return 'lts'
}
function Get-NodeInstallCandidates([string]$NvmExe, [bool]$Cn) {
  $mirrors = @()
  if ($Cn) { $mirrors += $NodeMirrorCn }
  $configured = Get-NvmNodeMirror $NvmExe
  if ($configured) { $mirrors += $configured }
  $mirrors += $NodeMirrorOfficial
  foreach ($mirror in @($mirrors | ForEach-Object { $_.TrimEnd('/') + '/' } | Select-Object -Unique)) {
    try {
      $catalog = Invoke-RestMethod -Uri ($mirror + 'index.json') -TimeoutSec 10 -UseBasicParsing -ErrorAction Stop
    } catch {
      Write-Warn "Node.js 版本列表不可用，跳过镜像: $mirror"
      continue
    }
    foreach ($candidate in @(Get-NodeLtsCandidatesFromCatalog $catalog $mirror)) {
      [pscustomobject]@{ Version = $candidate.Version; Mirror = $mirror }
    }
  }
}
function Install-NodeLtsWithRecovery([string]$NvmExe, [bool]$Cn) {
  $candidates = @(Get-NodeInstallCandidates $NvmExe $Cn)
  if (-not $candidates.Count) {
    Write-Warn '镜像版本列表均不可用，最后尝试 nvm install lts'
    Invoke-NodeCommand $NvmExe @('install','lts')
    return 'lts'
  }
  $activeMirror = Get-NvmNodeMirror $NvmExe
  $failures = @()
  foreach ($candidate in $candidates) {
    if (-not $activeMirror -or $activeMirror.TrimEnd('/') -ne $candidate.Mirror.TrimEnd('/')) {
      try {
        Set-NvmNodeMirror $NvmExe $candidate.Mirror
        $activeMirror = $candidate.Mirror
      } catch {
        $failures += "$($candidate.Version) @ $($candidate.Mirror): mirror configuration failed"
        Write-Warn "无法切换 Node.js 镜像 $($candidate.Mirror): $_"
        continue
      }
    }
    Write-Inst "尝试 Node.js LTS $($candidate.Version) ($($candidate.Mirror))"
    try {
      Invoke-NodeCommand $NvmExe @('install',$candidate.Version)
      return $candidate.Version
    } catch {
      $failures += "$($candidate.Version) @ $($candidate.Mirror)"
      Write-Warn "Node.js $($candidate.Version) 安装失败: $_；自动尝试下一版本/镜像"
    }
  }
  throw "Node.js LTS 所有备选安装均失败：$($failures -join '; ')"
}
function Install-Node {
  Write-Step 'Node.js: nvm-windows / Node.js LTS / npm / pnpm'
  $cn = ((Get-InstRegion) -eq 'cn')
  $nvmExe = Find-Nvm
  $nvmHome = if ($nvmExe) { Split-Path -Parent $nvmExe } else { Join-Path $env:LOCALAPPDATA 'nvm' }
  $symlink = if ($env:NVM_SYMLINK) { $env:NVM_SYMLINK } else { Join-Path $env:LOCALAPPDATA 'nvm-nodejs' }
  if (-not $nvmExe) {
    $existingNode = Get-Command node.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($existingNode) {
      $conflict = "检测到独立安装的 Node.js ($($existingNode.Source))，与 nvm-windows 冲突。请先在「应用和功能」中卸载后重试；脚本不会自动卸载。"
      if (-not $DryRun) { throw $conflict }
      # 预览只提示，继续列出后续步骤
      Write-Warn "实际运行会在此停止：$conflict"
    }
    if ($nvmHome -match ' ' -or $symlink -match ' ') { Write-Warn 'nvm-windows 不支持含空格的路径，可设置 NVM_HOME / NVM_SYMLINK 环境变量指定其他目录' }
    # nvm-windows 2.x 只提供安装器（且为社区未签名构建），这里固定使用 1.x 的免安装包。
    $tag = Get-Default '' 'INST_NVM_WINDOWS_VERSION' '1.2.2'
    $zip = Join-Path $Prefix 'nvm-noinstall.zip'
    Save-Download (Resolve-GhUrl "https://github.com/coreybutler/nvm-windows/releases/download/$tag/nvm-noinstall.zip") $zip
    if ($DryRun) { Write-Plan "解压到 $nvmHome，写入 settings.txt" }
    else {
      New-Item -ItemType Directory -Force -Path $nvmHome | Out-Null
      Expand-Archive -LiteralPath $zip -DestinationPath $nvmHome -Force
      Remove-Item -LiteralPath $zip -Force
      Set-NvmSetting $nvmHome 'root' $nvmHome
      Set-NvmSetting $nvmHome 'path' $symlink
      Set-NvmSetting $nvmHome 'arch' $(if ($Arch -eq 'x86') { '32' } else { '64' })
      Set-NvmSetting $nvmHome 'proxy' 'none'
    }
    $nvmExe = Join-Path $nvmHome 'nvm.exe'
  } else {
    Write-Inst "复用已有 nvm: $nvmExe"
    $settingsFile = Join-Path $nvmHome 'settings.txt'
    if (Test-Path -LiteralPath $settingsFile) {
      foreach ($line in Get-Content -LiteralPath $settingsFile) { if ($line -match '^path:\s*(.+)$') { $symlink = $Matches[1].Trim() } }
    }
  }
  if ($cn) {
    if ($DryRun) { Write-Plan "nvm node_mirror=$NodeMirrorCn npm_mirror=$NpmMirrorCn" }
    elseif (Test-Path -LiteralPath $nvmExe) { Set-NvmMirrors $nvmExe $true }
  }
  Set-UserEnv 'NVM_HOME' $nvmHome
  Set-UserEnv 'NVM_SYMLINK' $symlink
  Add-UserPath $nvmHome -Force
  Add-UserPath $symlink -Force
  if ($cn -and -not $NpmRegistry) { $script:NpmRegistry = Get-PresetNpm 'npmmirror' }
  $nodeTarget = 'lts'
  if ($DryRun) { Invoke-Native $nvmExe @('install',$nodeTarget) }
  else { $nodeTarget = Install-NodeLtsWithRecovery $nvmExe $cn }
  Write-Inst 'nvm use 需要创建符号链接，可能弹出 UAC 授权窗口'
  Invoke-Native $nvmExe @('use',$nodeTarget)
  if ($DryRun) { Invoke-NpmGlobal @('pnpm'); return }
  $env:Path = "$symlink;$env:Path"
  $nodeExe = Join-Path $symlink 'node.exe'
  if (-not (Test-Path -LiteralPath $nodeExe)) { throw "nvm use $nodeTarget 未生成可用的 Node.js；请在管理员终端运行 nvm use $nodeTarget，或开启 Windows「开发者模式」后重试。" }
  Invoke-NpmGlobal @('pnpm')
  Write-Ok ("node {0}  npm {1}  pnpm {2}" -f (& $nodeExe --version), (& (Join-Path $symlink 'npm.cmd') --version), (& (Join-Path $symlink 'pnpm.cmd') --version 2>$null))
}

# ---------------------------------------------------------------- Python
function Find-PyenvCommand {
  foreach ($name in @('pyenv.bat','pyenv.cmd','pyenv.ps1','pyenv.exe')) {
    $command = Get-Command $name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command }
  }
  return $null
}
function Resolve-PythonVersion([string]$Requested, [string[]]$Available) {
  if ($Requested -ne 'latest' -and $Requested -notmatch '^3\.\d+(\.\d+)?$') {
    throw 'PythonVersion 必须是 latest、3.x 或完整的 3.x.y 稳定版本'
  }
  $versions = @($Available | ForEach-Object { $_.Trim() } | Where-Object {
    $_ -match '^3\.\d+\.\d+$' -and ($Requested -eq 'latest' -or $_ -eq $Requested -or $_.StartsWith($Requested + '.'))
  } | ForEach-Object { [version]$_ } | Sort-Object -Descending)
  if (-not $versions.Count) { throw "pyenv 没有返回匹配 $Requested 的稳定版本" }
  return $versions[0].ToString()
}
function Install-Python {
  Write-Step 'Python: pyenv-win / Python / Miniconda'
  $cn = ((Get-InstRegion) -eq 'cn')
  $pyenvRoot = Join-Path $env:USERPROFILE '.pyenv'
  $pyenvHome = Join-Path $pyenvRoot 'pyenv-win'
  $pyenvCommand = Find-PyenvCommand
  if (-not $pyenvCommand -and -not (Test-Path -LiteralPath (Join-Path $pyenvHome 'bin\pyenv.bat'))) {
    if (Test-Path -LiteralPath $pyenvHome) { throw "$pyenvHome 已存在但不完整，请检查后重试（未覆盖）" }
    $zip = Join-Path $Prefix 'pyenv-win.zip'
    Save-Download (Resolve-GhUrl 'https://github.com/pyenv-win/pyenv-win/archive/refs/heads/master.zip') $zip
    if ($DryRun) { Write-Plan "解压 pyenv-win 到 $pyenvRoot" }
    else {
      $staging = Join-Path $Prefix ('pyenv-' + [Guid]::NewGuid().ToString('N'))
      Expand-Archive -LiteralPath $zip -DestinationPath $staging -Force
      New-Item -ItemType Directory -Force -Path $pyenvRoot | Out-Null
      Move-Item -LiteralPath (Join-Path $staging 'pyenv-win-master\pyenv-win') -Destination $pyenvHome
      Remove-Item -LiteralPath $staging, $zip -Recurse -Force
    }
  } elseif ($pyenvCommand) {
    $pyenvHome = Split-Path (Split-Path $pyenvCommand.Source)
    Write-Inst "复用已有 pyenv-win: $pyenvHome"
  }
  foreach ($name in @('PYENV','PYENV_ROOT','PYENV_HOME')) { Set-UserEnv $name ($pyenvHome.TrimEnd('\') + '\') }
  Add-UserPath (Join-Path $pyenvHome 'bin') -Force
  Add-UserPath (Join-Path $pyenvHome 'shims') -Force
  if ($cn) { Set-UserEnv 'PYTHON_BUILD_MIRROR_URL' $PythonMirrorCn }
  $pyenv = Join-Path $pyenvHome 'bin\pyenv.bat'
  if ($DryRun) {
    Write-Plan "pyenv update; pyenv install $PythonVersion; pyenv global"
  } else {
    try { Invoke-NodeCommand $pyenv @('update') } catch { Write-Warn "pyenv update 失败，使用本地缓存的版本列表: $_" }
    $available = @(Invoke-NativeCapture $pyenv @('install','--list'))
    $resolved = Resolve-PythonVersion $PythonVersion $available
    Write-Inst "选择 Python $resolved"
    Invoke-NodeCommand $pyenv @('install','--quiet','--skip-existing',$resolved)
    Invoke-NodeCommand $pyenv @('global',$resolved)
    Invoke-NodeCommand $pyenv @('rehash')
    Write-Ok ("Python " + ((& $pyenv @('version')) -join ' '))
  }
  Install-Miniconda
}
function Install-Miniconda {
  $condaRoot = Get-Default '' 'INST_CONDA_DIR' (Join-Path $env:USERPROFILE 'miniconda3')
  if (Test-Path -LiteralPath (Join-Path $condaRoot 'Scripts\conda.exe')) {
    Write-Inst "复用已有 Miniconda: $condaRoot"
  } else {
    if (Test-Path -LiteralPath $condaRoot) { throw "Miniconda 目录已存在但不完整: $condaRoot" }
    if ($condaRoot -match ' ') { throw "Miniconda 安装路径不能包含空格: $condaRoot（可设置 INST_CONDA_DIR）" }
    $condaArch = if ($Arch -eq 'x86') { 'x86' } else { 'x86_64' }
    $file = "Miniconda3-latest-Windows-$condaArch.exe"
    $site = if ((Get-InstRegion) -eq 'cn') { (Get-PresetConda $(if ($MirrorPreset) { $MirrorPreset } else { 'tuna' })) + '/miniconda' } else { 'https://repo.anaconda.com/miniconda' }
    $installer = Join-Path $Prefix $file
    Save-Download "$site/$file" $installer
    # /D 必须是最后一个参数且不能加引号，因此整体作为一个字符串传递。
    Invoke-CheckedProcess $installer "/InstallationType=JustMe /RegisterPython=0 /AddToPath=0 /S /D=$condaRoot" "安装 Miniconda 到 $condaRoot"
    if (-not $DryRun) {
      Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue
      if (-not (Test-Path -LiteralPath (Join-Path $condaRoot 'Scripts\conda.exe'))) { throw "Miniconda 安装后未找到 conda.exe: $condaRoot" }
    }
  }
  # 只把 condabin 加入 PATH，避免 base 环境的 python 覆盖 pyenv。
  Add-UserPath (Join-Path $condaRoot 'condabin') -Force
  if ((Get-InstRegion) -eq 'cn') { Set-CondaMirror (Get-PresetConda $(if ($MirrorPreset) { $MirrorPreset } else { 'tuna' })) }
}

# ---------------------------------------------------------------- 镜像
function Set-NpmMirror([string]$Url) {
  Assert-HttpsUrl $Url 'NpmRegistry'
  $npm = Get-NpmCommand
  if ($npm) { Invoke-Native $npm @('config','set','registry',$Url) }
  elseif ($DryRun) { Write-Plan "写入 ~\.npmrc registry=$Url" }
  else {
    $rc = Join-Path $env:USERPROFILE '.npmrc'
    $lines = @()
    if (Test-Path -LiteralPath $rc) { $lines = @(Get-Content -LiteralPath $rc | Where-Object { $_ -notmatch '^registry=' }) }
    Write-Utf8File $rc ((($lines + "registry=$Url") -join "`n") + "`n")
  }
  Write-Ok "npm / pnpm registry: $Url"
}
function Set-PipMirror([string]$Url) {
  Assert-HttpsUrl $Url 'PipIndex'
  $python = $null
  foreach ($candidate in @('python.exe','py.exe')) {
    $command = Get-Command $candidate -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command -and $command.Source -notmatch 'WindowsApps') { $python = $command.Source; break }
  }
  if ($python) { Invoke-Native $python @('-m','pip','config','--user','set','global.index-url',$Url) }
  elseif ($DryRun) { Write-Plan "写入 %APPDATA%\pip\pip.ini index-url=$Url" }
  else { Write-Utf8File (Join-Path $env:APPDATA 'pip\pip.ini') "[global]`r`nindex-url = $Url`r`n" }
  Set-UserEnv 'UV_DEFAULT_INDEX' $Url
  Write-Ok "pip index-url: $Url"
}
function Set-CondaMirror([string]$Base) {
  $condarc = Join-Path $env:USERPROFILE '.condarc'
  if ($DryRun) { Write-Plan "写入 $condarc (conda 镜像: $(if ($Base) { $Base } else { '官方' }))"; return }
  $backup = "$condarc.inst.bak"
  if ((Test-Path -LiteralPath $condarc) -and -not (Test-Path -LiteralPath $backup)) { Copy-Item -LiteralPath $condarc -Destination $backup }
  if (-not $Base) {
    if (Test-Path -LiteralPath $backup) { Move-Item -LiteralPath $backup -Destination $condarc -Force } else { Remove-Item -LiteralPath $condarc -Force -ErrorAction SilentlyContinue }
    Write-Ok 'conda 已恢复官方源'; return
  }
  Write-Utf8File $condarc (@(
    'channels:', '  - defaults', 'show_channel_urls: true', 'default_channels:',
    "  - $Base/pkgs/main", "  - $Base/pkgs/r", "  - $Base/pkgs/msys2",
    'custom_channels:', "  conda-forge: $Base/cloud", "  pytorch: $Base/cloud", ''
  ) -join "`n")
  Write-Ok "conda 镜像: $Base"
}
function Set-ToolchainMirror([bool]$Enabled) {
  $nvmExe = Find-Nvm
  if ($nvmExe) { Set-NvmMirrors $nvmExe $Enabled }
  elseif ($DryRun) { Write-Plan "nvm node_mirror/npm_mirror（未安装 nvm，安装时生效）" }
  Set-UserEnv 'PYTHON_BUILD_MIRROR_URL' $(if ($Enabled) { $PythonMirrorCn } else { '' })
  Write-Ok $(if ($Enabled) { 'nvm / pyenv-win 下载镜像已启用' } else { 'nvm / pyenv-win 下载镜像已关闭' })
}
# Windows 的「系统源」指 winget 源；只有中科大提供 winget 镜像。需要管理员权限。
function Set-WingetMirror([string]$Target) {
  $winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $winget) { Write-Warn '未找到 winget，跳过系统源'; return }
  if ($Target -eq 'official') { $commands = 'winget source reset --force' }
  else {
    $url = if ($Target -match '^https://') { $Target } else { 'https://mirrors.ustc.edu.cn/winget-source' }
    Assert-HttpsUrl $url 'SystemMirror'
    $commands = "winget source remove winget; winget source add winget $url --trust-level trusted"
  }
  Write-Inst "将以管理员身份执行: $commands"
  if (-not $ApplySystemMirror -and -not (Confirm-Inst '确认修改 winget 系统源')) { Write-Warn '未修改 winget 源；非交互模式请追加 -ApplySystemMirror'; return }
  if ($DryRun) { Write-Plan $commands; return }
  if (Test-Admin) { & powershell.exe -NoProfile -Command $commands }
  else { Start-Process powershell.exe -Verb RunAs -Wait -ArgumentList @('-NoProfile','-Command',$commands) }
  Write-Ok 'winget 源已更新'
}
function Set-Mirrors {
  Write-Step '镜像配置'
  $preset = $MirrorPreset
  if (-not $preset -and (Get-InstRegion) -eq 'cn') { $preset = 'tuna' }
  $npmUrl = $NpmRegistry; $pipUrl = $PipIndex
  if (-not $npmUrl -and $preset) { $npmUrl = Get-PresetNpm $preset }
  if (-not $pipUrl -and $preset) { $pipUrl = Get-PresetPip $preset }
  if ($npmUrl) { Assert-HttpsUrl $npmUrl 'NpmRegistry' }
  if ($pipUrl) { Assert-HttpsUrl $pipUrl 'PipIndex' }
  if (-not ($npmUrl -or $pipUrl -or $SystemMirror -or $preset)) {
    Write-Inst '当前区域无需镜像；可用 -MirrorPreset tuna|aliyun|ustc|tencent|huawei 指定'; return
  }
  if ($npmUrl) { Set-NpmMirror $npmUrl }
  if ($pipUrl) { Set-PipMirror $pipUrl }
  if ($preset) { Set-ToolchainMirror ($preset -ne 'official'); Set-CondaMirror (Get-PresetConda $preset) }
  if ($SystemMirror -or $ApplySystemMirror) { Set-WingetMirror $(if ($SystemMirror) { $SystemMirror } else { $preset }) }
  else { Write-Inst 'winget 系统源未修改；如需切换请追加 -ApplySystemMirror 或 -SystemMirror ustc' }
}

# ---------------------------------------------------------------- Agents CLI
# Ps1Args 用于跳过官方脚本的交互式引导；Pi 的 install.ps1 未写入官方文档，因此只用 npm。
$AgentTable = @(
  @{ Id = 'claude';   Name = 'Claude Code';  Bin = 'claude';   Npm = '@anthropic-ai/claude-code';       Ps1 = 'https://claude.ai/install.ps1';                    Ps1Args = @();             Upgrade = @('update') },
  @{ Id = 'codex';    Name = 'Codex CLI';    Bin = 'codex';    Npm = '@openai/codex';                   Ps1 = 'https://chatgpt.com/codex/install.ps1';            Ps1Args = @();             Upgrade = @('update') },
  @{ Id = 'gemini';   Name = 'Gemini CLI';   Bin = 'gemini';   Npm = '@google/gemini-cli';              Ps1 = '';                                                 Ps1Args = @();             Upgrade = @() },
  @{ Id = 'opencode'; Name = 'OpenCode';     Bin = 'opencode'; Npm = 'opencode-ai';                     Ps1 = '';                                                 Ps1Args = @();             Upgrade = @('upgrade') },
  @{ Id = 'grok';     Name = 'Grok Build';   Bin = 'grok';     Npm = '';                                Ps1 = 'https://x.ai/cli/install.ps1';                     Ps1Args = @();             Upgrade = @('update') },
  @{ Id = 'openclaw'; Name = 'OpenClaw';     Bin = 'openclaw'; Npm = 'openclaw';                        Ps1 = 'https://openclaw.ai/install.ps1';                  Ps1Args = @('-NoOnboard'); Upgrade = @('update') },
  @{ Id = 'hermes';   Name = 'Hermes Agent'; Bin = 'hermes';   Npm = '';                                Ps1 = 'https://hermes-agent.nousresearch.com/install.ps1'; Ps1Args = @('-SkipSetup'); Upgrade = @('update') },
  @{ Id = 'pi';       Name = 'Pi';           Bin = 'pi';       Npm = '@earendil-works/pi-coding-agent'; Ps1 = '';                                                 Ps1Args = @();             Upgrade = @('update') }
)
function Get-Agent([string]$Id) { return ($AgentTable | Where-Object { $_.Id -eq $Id } | Select-Object -First 1) }
function Install-Agent([string]$Id, [string]$Method) {
  $agent = Get-Agent $Id
  if (-not $agent) { throw "未知 Agent: $Id（可选: $(($AgentTable | ForEach-Object { $_.Id }) -join ',')）" }
  if ($Method -eq 'auto') {
    $Method = if ($agent.Ps1 -and ((Get-InstRegion) -ne 'cn' -or -not $agent.Npm)) { 'official' } else { 'npm' }
  }
  if ($Method -eq 'official' -and -not $agent.Ps1) { if ($agent.Npm) { Write-Warn "$($agent.Name) 无 Windows 官方脚本，改用 npm"; $Method = 'npm' } }
  if ($Method -eq 'npm' -and -not $agent.Npm) { if ($agent.Ps1) { Write-Warn "$($agent.Name) 无 npm 包，改用官方脚本"; $Method = 'official' } }
  if (-not $agent.Npm -and -not $agent.Ps1) {
    Write-Warn "$($agent.Name) 暂无 Windows 原生安装方式，请在 WSL 中运行: curl -fsSL $InstBase/install.sh | sh -s -- --agents --agent-list $Id"
    return
  }
  Write-Inst "安装 $($agent.Name) ($Method)"
  if ($Method -eq 'npm') { Invoke-NpmGlobal @($agent.Npm) } else { Invoke-OfficialPs1 (Resolve-GhUrl $agent.Ps1) $agent.Ps1Args; Add-UserPath (Join-Path $env:USERPROFILE '.local\bin') }
}
function Install-Agents {
  Write-Step 'Agents CLI'
  if ($AgentPackages) {
    Invoke-NpmGlobal @($AgentPackages -split ',' | Where-Object { $_ })
    if (-not $AgentList) { return }
  }
  $ids = if ($AgentList -eq 'all') { $AgentTable | ForEach-Object { $_.Id } } elseif ($AgentList) { $AgentList -split ',' } else { $DefaultAgents -split ',' }
  if ($ids | Where-Object { -not (Get-Agent $_) }) { throw "未知 Agent: $(($ids | Where-Object { -not (Get-Agent $_) }) -join ',')" }
  $failed = @()
  foreach ($id in ($ids | Where-Object { $_ })) {
    try { Install-Agent $id $AgentMethod } catch { Write-Fail "$id : $_"; $failed += $id }
  }
  if ($failed.Count) { throw "安装失败: $($failed -join ', ')" }
}

# ---------------------------------------------------------------- 桌面端
function Get-RedirectLocation([string]$Url) {
  $curl = Get-Command curl.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  $location = ''
  if ($curl) { $location = [string](& $curl.Source --proto '=https' -s -o NUL --max-time 20 -w '%{redirect_url}' $Url) }
  else {
    $request = [Net.HttpWebRequest]::Create($Url)
    $request.AllowAutoRedirect = $false; $request.Timeout = 20000
    try { $response = $request.GetResponse() } catch [Net.WebException] { $response = $_.Exception.Response; if (-not $response) { throw } }
    try { $location = [string]$response.Headers['Location'] } finally { $response.Close() }
  }
  if (-not $location) { throw "无法解析下载地址: $Url" }
  Assert-HttpsUrl $location '重定向地址'
  return $location
}
# Claude 的 exe/dmg 跳转地址对脚本启用了 Cloudflare 验证；官方文档给出的 MSIX 跳转可用，
# 同一版本目录下同名的 .exe（Squirrel，支持 --silent）也可下载。
$ClaudeMsixRedirect = "https://claude.ai/api/desktop/win32/$(if ($Arch -eq 'arm64') { 'arm64' } else { 'x64' })/msix/latest/redirect"
# Codex 桌面端已并入 ChatGPT 桌面端，Windows 只提供 MSIX / Microsoft Store。
$CodexMsixUrl = "https://persistent.oaistatic.com/codex-app-prod/ChatGPT-$(if ($Arch -eq 'arm64') { 'arm64' } else { 'x64' }).msix"
function Get-DesktopUrl([string]$App, [string]$Kind = 'exe') {
  if ($App -eq 'claude') {
    if ($ClaudeDesktopUrl) { return $ClaudeDesktopUrl }
    if ($DryRun) { Write-Plan "解析 $ClaudeMsixRedirect 得到最新版本"; return "https://downloads.claude.ai/releases/win32/latest/Claude.$Kind" }
    $msix = Get-RedirectLocation $ClaudeMsixRedirect
    if ($Kind -eq 'exe') { return ($msix -replace '\.msix$', '.exe') }
    return $msix
  }
  if ($App -eq 'codex') { if ($CodexDesktopUrl) { return $CodexDesktopUrl }; return $CodexMsixUrl }
  return ''
}
function Install-Msix([string]$Path) {
  if ($DryRun) { Write-Plan "Add-AppxPackage $Path"; return }
  Add-AppxPackage -Path $Path -ForceApplicationShutdown
}
# Squirrel 安装器不支持自定义目录：安装后把目录移动到指定位置，并在原位置留下目录联接（junction）。
function Move-AppWithJunction([string]$Source, [string]$TargetRoot, [string]$ProcessName) {
  $target = Join-Path $TargetRoot (Split-Path -Leaf $Source)
  if ($DryRun) { Write-Plan "移动 $Source -> $target 并创建目录联接"; return }
  if (-not (Test-Path -LiteralPath $Source)) { Write-Warn "未找到 $Source，跳过移动"; return }
  $item = Get-Item -LiteralPath $Source -Force
  if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { Write-Inst "$Source 已是目录联接"; return }
  if ($ProcessName) { Get-Process -Name $ProcessName -ErrorAction SilentlyContinue | Stop-Process -Force; Start-Sleep -Seconds 2 }
  New-Item -ItemType Directory -Force -Path $TargetRoot | Out-Null
  if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
  & robocopy.exe $Source $target /E /MOVE /NFL /NDL /NJH /NJS /NP | Out-Null
  if ($LASTEXITCODE -ge 8) { throw "移动 $Source 失败 (robocopy $LASTEXITCODE)" }
  if (Test-Path -LiteralPath $Source) { Remove-Item -LiteralPath $Source -Recurse -Force }
  New-Item -ItemType Junction -Path $Source -Target $target | Out-Null
  Write-Ok "已安装到 $target（原位置 $Source 为目录联接）"
}
function Install-DesktopApp([string]$App, [string]$Dir) {
  $cache = Join-Path $Prefix 'desktop-cache'
  if ($App -eq 'codex') {
    $url = Get-DesktopUrl 'codex'
    Assert-HttpsUrl $url 'codex desktop URL'
    if ($Dir) { Write-Warn 'Codex（ChatGPT 桌面端）仅提供 MSIX，安装位置由系统管理，无法自定义目录' }
    try {
      $file = Join-Path $cache 'ChatGPT.msix'
      Save-Download $url $file
      Install-Msix $file
    } catch {
      $winget = Get-Command winget.exe -ErrorAction SilentlyContinue | Select-Object -First 1
      if (-not $winget) { throw "Codex 桌面端安装失败: $_（可从 Microsoft Store 安装 9PLM9XGG6VKS）" }
      Write-Warn "MSIX 安装失败，改用 Microsoft Store: $_"
      Invoke-Native $winget.Source @('install','--id','9PLM9XGG6VKS','--source','msstore','--accept-package-agreements','--accept-source-agreements')
    }
    if (-not $DryRun) { Write-Ok 'Codex 桌面端已安装（开始菜单中的 ChatGPT，可切换到 Codex）' }
    return
  }
  if ($App -ne 'claude') { Write-Warn "未知桌面端应用: $App（可选 claude,codex）"; return }
  $url = Get-DesktopUrl 'claude' 'exe'
  Assert-HttpsUrl $url 'claude desktop URL'
  if ($url -match '\.msix(bundle)?$') {
    $file = Join-Path $cache 'Claude.msix'; Save-Download $url $file; Install-Msix $file
    if ($Dir) { Write-Warn 'MSIX 安装位置由系统管理，无法自定义目录' }
    return
  }
  $installer = Join-Path $cache 'Claude-Setup.exe'
  try { Save-Download $url $installer }
  catch {
    if ($ClaudeDesktopUrl) { throw }
    Write-Warn "exe 安装包下载失败，改用官方 MSIX（无法自定义目录）: $_"
    $file = Join-Path $cache 'Claude.msix'; Save-Download (Get-DesktopUrl 'claude' 'msix') $file; Install-Msix $file
    return
  }
  $extra = Get-Default $ClaudeDesktopArgs 'INST_DESKTOP_CLAUDE_ARGS' '--silent'
  Invoke-CheckedProcess $installer $extra '安装 Claude Desktop' -Visible
  if (-not $DryRun) { Remove-Item -LiteralPath $installer -Force -ErrorAction SilentlyContinue }
  if ($Dir) { Move-AppWithJunction (Join-Path $env:LOCALAPPDATA 'AnthropicClaude') $Dir 'claude' }
  if (-not $DryRun) { Write-Ok 'Claude Desktop 已安装' }
}
function Install-Desktop {
  Write-Step '桌面端'
  $dir = $DesktopDir
  if (-not $dir -and $Interactive) { $dir = Read-Choice '安装目录（留空使用默认位置）' '' }
  foreach ($app in ($DesktopApps -split ',' | Where-Object { $_ })) { Install-DesktopApp $app.Trim() $dir }
}

# ---------------------------------------------------------------- 地址配置
function Merge-JsonObject($Target, $Patch) {
  foreach ($prop in @($Patch.PSObject.Properties)) {
    $existing = $Target.PSObject.Properties[$prop.Name]
    if ($null -eq $prop.Value) { if ($existing) { $Target.PSObject.Properties.Remove($prop.Name) }; continue }
    if ($prop.Value -is [Management.Automation.PSCustomObject] -and $existing -and $existing.Value -is [Management.Automation.PSCustomObject]) {
      Merge-JsonObject $existing.Value $prop.Value | Out-Null
    } elseif ($existing) { $existing.Value = $prop.Value }
    else { $Target | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value }
  }
  return $Target
}
function Merge-JsonFile([string]$Path, [hashtable]$Patch) {
  if ($DryRun) { Write-Plan "合并配置到 $Path"; return }
  $current = New-Object PSObject
  if ((Test-Path -LiteralPath $Path) -and (Get-Content -LiteralPath $Path -Raw -Encoding UTF8).Trim()) {
    try { $current = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { throw "无法解析 $Path，请先修复该 JSON 文件" }
  }
  $patchObject = $Patch | ConvertTo-Json -Depth 32 | ConvertFrom-Json
  $merged = Merge-JsonObject $current $patchObject
  Write-Utf8File $Path (($merged | ConvertTo-Json -Depth 32) + "`n")
}
function Set-DotenvValue([string]$Path, [string]$Key, [string]$Value) {
  if ($DryRun) { Write-Plan "写入 $Path : $Key"; return }
  $lines = @()
  if (Test-Path -LiteralPath $Path) { $lines = @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { $_ -notmatch "^$([regex]::Escape($Key))=" }) }
  if ($Value) { $lines += "$Key=$Value" }
  Write-Utf8File $Path (($lines -join "`n") + "`n")
}
function Set-CodexConfig([string]$Url, [string]$ModelName) {
  $path = Join-Path $env:USERPROFILE '.codex\config.toml'
  if ($DryRun) { Write-Plan "写入 $path [model_providers.inst]"; return }
  $lines = @()
  if (Test-Path -LiteralPath $path) { $lines = @(Get-Content -LiteralPath $path -Encoding UTF8) }
  $kept = New-Object Collections.Generic.List[string]
  $top = $true; $skip = $false
  foreach ($line in $lines) {
    if ($line -match '^\s*\[') { $top = $false; $skip = ($line -match '^\s*\[model_providers\.inst\]\s*$') }
    if ($skip) { continue }
    if ($top -and $line -match '^\s*model_provider\s*=') { continue }
    if ($top -and $ModelName -and $line -match '^\s*model\s*=') { continue }
    $kept.Add($line)
  }
  $output = New-Object Collections.Generic.List[string]
  $output.Add('model_provider = "inst"')
  if ($ModelName) { $output.Add("model = `"$ModelName`"") }
  foreach ($line in $kept) { $output.Add($line) }
  while ($output.Count -and -not $output[$output.Count - 1].Trim()) { $output.RemoveAt($output.Count - 1) }
  $output.AddRange([string[]]@('', '[model_providers.inst]', 'name = "inst"', "base_url = `"$Url`"", 'env_key = "INST_CODEX_API_KEY"', 'wire_api = "responses"'))
  Write-Utf8File $path (($output -join "`n") + "`n")
}
function Set-AgentEndpointFor([string]$Id, [string]$Url, [string]$Key, [string]$ModelName) {
  Assert-HttpsUrl $Url "$Id Base URL"
  $Url = $Url.TrimEnd('/')
  switch ($Id) {
    'claude' {
      $envPatch = @{ ANTHROPIC_BASE_URL = $Url }
      if ($Key) { $envPatch.ANTHROPIC_AUTH_TOKEN = $Key }
      if ($ModelName) { $envPatch.ANTHROPIC_MODEL = $ModelName }
      Merge-JsonFile (Join-Path $env:USERPROFILE '.claude\settings.json') @{ env = $envPatch }
      Merge-JsonFile (Join-Path $env:USERPROFILE '.claude.json') @{ hasCompletedOnboarding = $true }
    }
    'codex' {
      Set-CodexConfig $Url $ModelName
      if ($Key) { Set-UserEnv 'INST_CODEX_API_KEY' $Key }
    }
    'gemini' {
      $file = Join-Path $env:USERPROFILE '.gemini\.env'
      Set-DotenvValue $file 'GOOGLE_GEMINI_BASE_URL' $Url
      if ($Key) { Set-DotenvValue $file 'GEMINI_API_KEY' $Key }
      if ($ModelName) { Set-DotenvValue $file 'GEMINI_MODEL' $ModelName }
      # 跳过首次启动的认证方式选择
      if ($Key) { Merge-JsonFile (Join-Path $env:USERPROFILE '.gemini\settings.json') @{ security = @{ auth = @{ selectedType = 'gemini-api-key' } } } }
    }
    'pi' {
      $piDir = Get-Default '' 'PI_CODING_AGENT_DIR' (Join-Path $env:USERPROFILE '.pi\agent')
      $provider = @{ baseUrl = $Url; api = 'openai-completions'; models = @() }
      if ($ModelName) { $provider.models = @(@{ id = $ModelName }) }
      if ($Key) { $provider.apiKey = $Key }
      Merge-JsonFile (Join-Path $piDir 'models.json') @{ providers = @{ inst = $provider } }
      if ($ModelName) { Merge-JsonFile (Join-Path $piDir 'settings.json') @{ defaultProvider = 'inst'; defaultModel = $ModelName } }
    }
    'opencode' {
      $options = @{ baseURL = $Url }
      if ($Key) { $options.apiKey = $Key }
      $models = @{}
      if ($ModelName) { $models[$ModelName] = @{ name = $ModelName } }
      $patch = @{ '$schema' = 'https://opencode.ai/config.json'; provider = @{ inst = @{ npm = '@ai-sdk/openai-compatible'; name = 'inst'; options = $options; models = $models } } }
      if ($ModelName) { $patch.model = "inst/$ModelName" }
      Merge-JsonFile (Join-Path $env:USERPROFILE '.config\opencode\opencode.json') $patch
    }
    default {
      Set-UserEnv 'OPENAI_BASE_URL' $Url
      if ($Key) { Set-UserEnv 'OPENAI_API_KEY' $Key }
    }
  }
  Write-Ok "已配置 $Id -> $Url"
}
function Set-AgentEndpoints {
  Write-Step 'Agents 地址配置'
  $done = $false
  if ($AnthropicBaseUrl) { Set-AgentEndpointFor 'claude' $AnthropicBaseUrl (Get-Default '' 'INST_ANTHROPIC_API_KEY' $ApiKey) $Model; $done = $true }
  if ($OpenAiBaseUrl) { Set-AgentEndpointFor 'codex' $OpenAiBaseUrl (Get-Default '' 'INST_OPENAI_API_KEY' $ApiKey) $Model; $done = $true }
  if ($BaseUrl) {
    $ids = if ($Endpoint) { $Endpoint -split ',' } else { @('claude') }
    foreach ($id in ($ids | Where-Object { $_ })) { Set-AgentEndpointFor $id.Trim() $BaseUrl $ApiKey $Model }
    $done = $true
  }
  if (-not $done) { Write-Inst '未提供地址：使用 -Endpoint claude,codex -BaseUrl URL，密钥通过环境变量 INST_API_KEY 传入' }
}

# ---------------------------------------------------------------- 检查与更新
function Show-Check {
  Write-Step "环境检查  inst v$InstVersion  Windows $([Environment]::OSVersion.Version) $Arch  PowerShell $($PSVersionTable.PSVersion)"
  foreach ($tool in @('nvm','node','npm','pnpm','pyenv','python','conda','claude','codex','gemini','opencode','grok','openclaw','hermes','pi')) {
    $command = Get-Command $tool -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { Write-Host ('  {0,-10} ' -f $tool) -NoNewline; Write-Host $command.Source -ForegroundColor Green }
    else { Write-Host ('  {0,-10} ' -f $tool) -NoNewline; Write-Host '未找到' -ForegroundColor DarkGray }
  }
}
function Update-All {
  Write-Step '更新已安装工具'
  $nvmExe = Find-Nvm
  if ($nvmExe) {
    $nodeTarget = if ($DryRun) { 'lts' } else { Resolve-NodeInstallTarget $nvmExe ((Get-InstRegion) -eq 'cn') }
    Invoke-Native $nvmExe @('install',$nodeTarget)
    Invoke-Native $nvmExe @('use',$nodeTarget)
    Refresh-ProcessEnvironment
    Invoke-NpmGlobal @('pnpm@latest')
  }
  $pyenv = Find-PyenvCommand
  if ($pyenv) {
    if ($DryRun) { Write-Plan 'pyenv update; pyenv install <最新稳定版>' }
    else {
      try {
        Invoke-NodeCommand $pyenv.Source @('update')
        $resolved = Resolve-PythonVersion $PythonVersion @(Invoke-NativeCapture $pyenv.Source @('install','--list'))
        Invoke-NodeCommand $pyenv.Source @('install','--quiet','--skip-existing',$resolved)
      } catch { Write-Warn "Python 更新失败: $_" }
    }
  }
  $npm = Get-NpmCommand
  $npmPrefix = if ($npm -and -not $DryRun) { ((& $npm prefix -g) | Select-Object -Last 1) } else { '' }
  foreach ($agent in $AgentTable) {
    $command = Get-Command $agent.Bin -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { continue }
    try {
      if ($agent.Npm -and $npmPrefix -and $command.Source.StartsWith($npmPrefix, [StringComparison]::OrdinalIgnoreCase)) { Invoke-NpmGlobal @("$($agent.Npm)@latest") }
      elseif ($agent.Upgrade.Count) { Invoke-Native $command.Source $agent.Upgrade }
      elseif ($agent.Ps1) { Invoke-OfficialPs1 (Resolve-GhUrl $agent.Ps1) $agent.Ps1Args }
    } catch { Write-Warn "$($agent.Name) 更新失败: $_" }
  }
  Write-Ok '更新完成'
}

# ---------------------------------------------------------------- 脚本自更新与快捷命令
function Get-RemoteVersion {
  if ($env:INST_NO_UPDATE_CHECK) { return '' }
  try {
    $text = ([string](Invoke-RestMethod -Uri "$InstBase/VERSION" -TimeoutSec 3 -UseBasicParsing)).Trim()
    if ($text -match '^\d+(\.\d+)*$') { return $text }
  } catch { }
  return ''
}
function Get-SelfUpdateTarget {
  if ($env:INST_INSTALLER_PATH -and (Test-Path -LiteralPath $env:INST_INSTALLER_PATH)) { return $env:INST_INSTALLER_PATH }
  if (Test-Path -LiteralPath $ShortcutScript) { return $ShortcutScript }
  return ''
}
function Get-ScriptVersion([string]$Code) {
  if ($Code -match "(?m)^\`$InstVersion = '([^']+)'") { return $Matches[1] }
  return ''
}
function Get-RemoteScript {
  Assert-HttpsUrl $InstBase 'INST_RAW_BASE_URL'
  $bytes = (New-Object Net.WebClient).DownloadData("$InstBase/scripts/install-windows.ps1")
  $code = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
  $tokens = $null; $errors = $null
  [Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors) | Out-Null
  if ($errors.Count) { throw "下载的脚本校验失败: $($errors[0])" }
  return $code
}
function Save-ScriptFile([string]$Path, [string]$Code) {
  $dir = Split-Path -Parent $Path
  if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
  $temp = "$Path.$([Guid]::NewGuid().ToString('N')).tmp"
  # PowerShell 5.1 按系统代码页读取无 BOM 文件，因此保存为带 BOM 的 UTF-8。
  [IO.File]::WriteAllText($temp, $Code, (New-Object Text.UTF8Encoding $true))
  Move-Item -LiteralPath $temp -Destination $Path -Force
}
function Update-Installer {
  Write-Step '更新 inst 脚本'
  $target = Get-SelfUpdateTarget
  if (-not $target) { throw '自更新只支持本地文件模式：请先安装快捷命令（-InstallShortcut / 菜单 88），在线运行时每次都是最新版' }
  if (Test-Path -LiteralPath (Join-Path (Split-Path -Parent (Split-Path -Parent $target)) '.git')) { throw "$target 位于 git 仓库中，请使用 git pull 更新" }
  if ($DryRun) { Write-Plan "下载并校验 $InstBase/scripts/install-windows.ps1，然后替换 $target（旧版备份为 $target.bak）"; return }
  $current = Get-ScriptVersion ([IO.File]::ReadAllText($target, [Text.Encoding]::UTF8))
  $remote = Get-RemoteVersion
  if (-not $env:INST_FORCE_UPDATE -and $current -and $remote -and (Compare-InstVersion $remote $current) -le 0) {
    Write-Ok "已是最新版本 v$current（INST_FORCE_UPDATE=1 可强制重新下载）"; return
  }
  $code = Get-RemoteScript
  $newVersion = Get-ScriptVersion $code
  if (-not $newVersion) { throw '下载的脚本缺少版本号，未替换' }
  Copy-Item -LiteralPath $target -Destination "$target.bak" -Force -ErrorAction SilentlyContinue
  Save-ScriptFile $target $code
  Write-Ok "已更新: $target (v$current -> v$newVersion)，备份: $target.bak"
}
function Install-Shortcut {
  Write-Step '安装快捷命令 inst'
  if ($DryRun) { Write-Plan "保存脚本到 $ShortcutScript，并创建 $ShortcutBin\inst.cmd"; return }
  if ($PSCommandPath -and (Test-Path -LiteralPath $PSCommandPath) -and $PSCommandPath -ne $ShortcutScript) {
    Save-ScriptFile $ShortcutScript ([IO.File]::ReadAllText($PSCommandPath, [Text.Encoding]::UTF8).TrimStart([char]0xFEFF))
  } else {
    Save-ScriptFile $ShortcutScript (Get-RemoteScript)
  }
  New-Item -ItemType Directory -Force -Path $ShortcutBin | Out-Null
  [IO.File]::WriteAllText((Join-Path $ShortcutBin 'inst.cmd'), "@echo off`r`nsetlocal`r`nset INST_LAUNCHER=cmd`r`npowershell.exe -NoProfile -ExecutionPolicy Bypass -File `"%~dp0..\inst.ps1`" %*`r`n", (New-Object Text.ASCIIEncoding))
  # Git Bash 等 POSIX shell 使用的包装脚本
  [IO.File]::WriteAllText((Join-Path $ShortcutBin 'inst'), "#!/bin/sh`nexport INST_LAUNCHER=bash`nexec powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"`$(cygpath -w `"`$(dirname `"`$0`")/../inst.ps1`")`" `"`$@`"`n", (New-Object Text.ASCIIEncoding))
  Add-UserPath $ShortcutBin
  Write-Ok "已安装快捷命令，新开终端输入 inst 即可打开菜单（cmd / PowerShell / Git Bash）"
}
$AutoUpdateTask = 'inst-auto-update'
function Set-AutoUpdate([bool]$Enabled) {
  if ($Enabled) {
    if (-not (Test-Path -LiteralPath $ShortcutScript)) { Install-Shortcut }
    $action = "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$ShortcutScript`" -SelfUpdate -Quiet"
    $time = '04:{0:D2}' -f (Get-Random -Minimum 0 -Maximum 60) # 随机分钟，避免所有用户同一时刻请求
    if ($DryRun) { Write-Plan "创建计划任务 $AutoUpdateTask，每天 $time 执行 -SelfUpdate"; return }
    Invoke-Native 'schtasks.exe' @('/Create','/F','/SC','DAILY','/ST',$time,'/TN',$AutoUpdateTask,'/TR',$action)
    Write-Ok "已开启每日自动更新（计划任务 $AutoUpdateTask，每天 $time）"
  } else {
    & schtasks.exe /Delete /F /TN $AutoUpdateTask 2>$null | Out-Null
    Write-Ok '已关闭自动更新'
  }
}

# ---------------------------------------------------------------- 菜单
$script:RemoteVersion = ''
function Show-Banner {
  if ($Interactive) { Clear-Host }
  Write-Host @'
   _           _
  (_)_ __  ___| |_
  | | '_ \/ __| __|
  | | | | \__ \ |_
  |_|_| |_|___/\__|
'@ -ForegroundColor Cyan
  Write-Host "  v$InstVersion  " -NoNewline; Write-Host '跨平台开发环境 & AI Agents 安装器' -ForegroundColor DarkGray
  Write-Host '------------------------------------------------'
  # 入口脚本（install.cmd / inst.cmd / install.sh）通过 INST_LAUNCHER 告知调用方 shell
  $shell = switch ($env:INST_LAUNCHER) { 'cmd' { 'cmd' } 'bash' { 'Git Bash' } default { "PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor)" } }
  Write-Host " 系统: Windows $([Environment]::OSVersion.Version.Build) $Arch | Shell: $shell | 区域: $(Get-InstRegion)"
  if ($script:RemoteVersion -and (Compare-InstVersion $script:RemoteVersion $InstVersion) -gt 0) {
    Write-Host " 发现新版本 v$($script:RemoteVersion)，输入 00 更新" -ForegroundColor Yellow
  }
  Write-Host '------------------------------------------------'
}
function Write-MenuLine([string]$Key, [string]$Label, [string]$Hint = '') {
  Write-Host (' {0,-4} ' -f $Key) -ForegroundColor Green -NoNewline
  Write-Host ('{0,-16}' -f $Label) -NoNewline
  Write-Host $Hint -ForegroundColor DarkGray
}
function Invoke-MenuAction([scriptblock]$Action) {
  $ok = $true
  try { & $Action | Out-Host } catch { $ok = $false; Write-Fail "操作失败: $_" }
  Wait-Inst
  return $ok
}
function Select-Preset {
  Write-MenuLine 1 '清华 TUNA'; Write-MenuLine 2 '阿里云'; Write-MenuLine 3 '中科大 USTC'; Write-MenuLine 4 '腾讯云'; Write-MenuLine 5 '华为云'; Write-MenuLine 6 '官方源' '恢复默认'
  switch (Read-Choice '选择镜像' '1') { '1' { 'tuna' } '2' { 'aliyun' } '3' { 'ustc' } '4' { 'tencent' } '5' { 'huawei' } '6' { 'official' } default { '' } }
}
function Show-MirrorMenu {
  while ($true) {
    Show-Banner
    Write-Host ' 镜像源配置' -ForegroundColor White
    Write-MenuLine 1 '一键国内镜像' 'npm + pip + conda + nvm/pyenv 下载 (+winget)'
    Write-MenuLine 2 '系统源' 'winget（中科大镜像，需要管理员）'
    Write-MenuLine 3 'npm/pnpm 源'
    Write-MenuLine 4 'pip 源'
    Write-MenuLine 5 'conda 源'
    Write-MenuLine 6 'nvm/pyenv 下载镜像'
    Write-MenuLine 7 'GitHub 加速' "当前: $(if ($GhProxy) { $GhProxy } else { '未启用' })"
    Write-MenuLine 8 '恢复全部官方源'
    Write-MenuLine 0 '返回'
    $choice = Read-Choice '请选择'
    switch ($choice) {
      '1' { $p = Select-Preset; if ($p) { $script:MirrorPreset = $p; if (Confirm-Inst '同时切换 winget 系统源') { $script:ApplySystemMirror = $true }; Invoke-MenuAction { Set-Mirrors } | Out-Null; $script:ApplySystemMirror = $false } }
      '2' { $p = Select-Preset; if ($p) { $script:ApplySystemMirror = $true; Invoke-MenuAction { Set-WingetMirror $p } | Out-Null; $script:ApplySystemMirror = $false } }
      '3' { $p = Select-Preset; if ($p) { Invoke-MenuAction { Set-NpmMirror (Get-PresetNpm $p) } | Out-Null } }
      '4' { $p = Select-Preset; if ($p) { Invoke-MenuAction { Set-PipMirror (Get-PresetPip $p) } | Out-Null } }
      '5' { $p = Select-Preset; if ($p) { Invoke-MenuAction { Set-CondaMirror (Get-PresetConda $p) } | Out-Null } }
      '6' { $on = Confirm-Inst '启用 npmmirror 的 Node/Python 下载镜像' 'y'; Invoke-MenuAction { Set-ToolchainMirror $on } | Out-Null }
      '7' { $p = Read-Choice 'GitHub 代理前缀（如 https://gh-proxy.com，留空关闭）' ''; Invoke-MenuAction { if ($p) { Assert-HttpsUrl $p 'GhProxy' }; $script:GhProxy = $p; Set-UserEnv 'INST_GH_PROXY' $p } | Out-Null }
      '8' { $script:MirrorPreset = 'official'; Invoke-MenuAction { Set-Mirrors } | Out-Null }
      '0' { return }
      'q' { return }
    }
  }
}
function Show-AgentMenu {
  Show-Banner
  Write-Host ' Agents CLI 安装' -ForegroundColor White
  $i = 1
  foreach ($agent in $AgentTable) {
    $how = @(); if ($agent.Ps1) { $how += '官方' }; if ($agent.Npm) { $how += 'npm' }; if (-not $how.Count) { $how += 'WSL' }
    $mark = if (Get-Command $agent.Bin -ErrorAction SilentlyContinue) { ' 已安装' } else { '' }
    Write-MenuLine $i $agent.Name (($how -join '/') + $mark)
    $i++
  }
  Write-MenuLine a '全部'; Write-MenuLine 0 '返回'
  $choice = Read-Choice '选择（可多选，如 1 2 3）' '1 2 3 4'
  if ($choice -eq '0') { return }
  $ids = if ($choice -eq 'a') { 'all' } else {
    (@($choice -split '[,\s]+' | Where-Object { $_ -match '^\d+$' -and [int]$_ -ge 1 -and [int]$_ -le $AgentTable.Count } | ForEach-Object { $AgentTable[[int]$_ - 1].Id }) -join ',')
  }
  if (-not $ids) { return }
  Write-MenuLine 1 '自动' '优先官方脚本，否则 npm'; Write-MenuLine 2 '官方脚本'; Write-MenuLine 3 'npm'
  $method = switch (Read-Choice '安装方式' '1') { '2' { 'official' } '3' { 'npm' } default { 'auto' } }
  $script:AgentList = $ids; $script:AgentMethod = $method; $script:AgentPackages = ''
  Invoke-MenuAction { Install-Agents } | Out-Null
}
function Show-DesktopMenu {
  Show-Banner
  Write-Host ' Agents 桌面端' -ForegroundColor White
  Write-MenuLine 1 'Claude Desktop' '安装后可移动到指定目录（目录联接）'
  Write-MenuLine 2 'Codex Desktop' 'ChatGPT 桌面端 MSIX，目录由系统管理'
  Write-MenuLine 3 '全部'; Write-MenuLine 0 '返回'
  $apps = switch (Read-Choice '请选择' '3') { '1' { 'claude' } '2' { 'codex' } '3' { 'claude,codex' } default { '' } }
  if (-not $apps) { return }
  $script:DesktopApps = $apps
  $script:DesktopDir = Read-Choice '安装目录（留空使用默认位置，如 D:\Apps）' ''
  Invoke-MenuAction { Install-Desktop } | Out-Null
}
function Show-EndpointMenu {
  Show-Banner
  Write-Host ' Agents 地址配置（写入各 Agent 自己的配置文件）' -ForegroundColor White
  Write-MenuLine 1 'Claude Code' '~\.claude\settings.json'
  Write-MenuLine 2 'Codex CLI' '~\.codex\config.toml'
  Write-MenuLine 3 'Gemini CLI' '~\.gemini\.env'
  Write-MenuLine 4 'OpenCode' '~\.config\opencode\opencode.json'
  Write-MenuLine 5 'Pi' '~\.pi\agent\models.json'
  Write-MenuLine 6 '其他 (OpenAI 兼容)' 'OPENAI_BASE_URL / OPENAI_API_KEY'
  Write-MenuLine 0 '返回'
  $map = @{ '1' = 'claude'; '2' = 'codex'; '3' = 'gemini'; '4' = 'opencode'; '5' = 'pi'; '6' = 'openai' }
  $ids = (@((Read-Choice '选择（可多选）' '1') -split '[,\s]+' | Where-Object { $map.ContainsKey($_) } | ForEach-Object { $map[$_] }) -join ',')
  if (-not $ids) { return }
  $url = Read-Choice 'API Base URL (https://...)' ''
  if (-not $url) { return }
  $secure = Read-Host 'API Key（输入不回显，留空跳过）' -AsSecureString
  $key = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure))
  $script:Endpoint = $ids; $script:BaseUrl = $url; $script:ApiKey = $key; $script:Model = Read-Choice '默认模型（可留空）' ''
  $script:AnthropicBaseUrl = ''; $script:OpenAiBaseUrl = ''
  Invoke-MenuAction { Set-AgentEndpoints } | Out-Null
}
function Show-UpdateMenu {
  Show-Banner
  Write-Host " 脚本更新  当前 v$InstVersion  最新 v$(if ($script:RemoteVersion) { $script:RemoteVersion } else { '未知' })" -ForegroundColor White
  Write-MenuLine 1 '立即更新'; Write-MenuLine 2 '开启每日自动更新'; Write-MenuLine 3 '关闭自动更新'; Write-MenuLine 0 '返回'
  switch (Read-Choice '请选择' '1') {
    '1' {
      if (-not (Get-SelfUpdateTarget)) {
        if ($IsRemote) { Write-Inst '在线运行模式每次都是最新版，已为你安装快捷命令以便离线使用' }
        Invoke-MenuAction { Install-Shortcut } | Out-Null
      } elseif (Invoke-MenuAction { Update-Installer }) {
        Write-Inst '请重新运行 inst 以使用新版本'
        $script:ExitMenu = $true
      }
    }
    '2' { Invoke-MenuAction { Set-AutoUpdate $true } | Out-Null }
    '3' { Invoke-MenuAction { Set-AutoUpdate $false } | Out-Null }
  }
}
function Show-MainMenu {
  $script:Interactive = $true
  $script:RemoteVersion = Get-RemoteVersion
  $script:ExitMenu = $false
  while (-not $script:ExitMenu) {
    Show-Banner
    Write-MenuLine 1 'Node.js 环境' 'nvm-windows / Node.js LTS / npm / pnpm'
    Write-MenuLine 2 'Python 环境' 'pyenv-win / Python / Miniconda'
    Write-MenuLine 3 '镜像源配置' 'winget / npm / pip / conda'
    Write-MenuLine 4 'Agents CLI' 'Claude Code / Codex / Gemini / OpenCode / Grok / OpenClaw / Hermes / Pi'
    Write-MenuLine 5 'Agents 桌面端' 'Claude / Codex Desktop'
    Write-MenuLine 6 'Agents 地址配置' 'API Base URL / Key'
    Write-Host '------------------------------------------------'
    Write-MenuLine 7 '一键安装' '1 + 2 + 3 + 4'
    Write-MenuLine 8 '环境检查'
    Write-MenuLine 9 '更新已安装工具'
    Write-Host '------------------------------------------------'
    Write-MenuLine 00 '脚本更新' $(if (Test-Path -LiteralPath $ShortcutScript) { '快捷命令: inst' } else { '' })
    Write-MenuLine 88 '安装快捷命令' 'inst'
    Write-MenuLine 0 '退出'
    Write-Host '------------------------------------------------'
    switch (Read-Choice '请输入你的选择') {
      '1' { Invoke-MenuAction { Install-Node } | Out-Null }
      '2' { Invoke-MenuAction { Install-Python } | Out-Null }
      '3' { Show-MirrorMenu }
      '4' { Show-AgentMenu }
      '5' { Show-DesktopMenu }
      '6' { Show-EndpointMenu }
      '7' { Invoke-MenuAction { Set-Mirrors; Install-Node; Install-Python; Install-Agents } | Out-Null }
      '8' { Invoke-MenuAction { Show-Check } | Out-Null }
      '9' { Invoke-MenuAction { Update-All } | Out-Null }
      '00' { Show-UpdateMenu }
      '88' { Invoke-MenuAction { Install-Shortcut } | Out-Null }
      '0' { $script:ExitMenu = $true }
      'q' { $script:ExitMenu = $true }
    }
  }
  Write-Host '再见'
}

function Show-Usage {
  @"
inst v$InstVersion  跨平台开发环境 & AI Agents 安装器 (Windows)

用法: inst                         打开交互菜单
      inst [组件] [选项]            非交互执行
      在线: & ([scriptblock]::Create((irm $InstBase/install.ps1))) -All

组件:
  -All            Node + Python + 镜像 + Agents CLI
  -Node           nvm-windows、Node.js LTS、npm、pnpm
  -Python         pyenv-win、Python 最新稳定版、Miniconda
  -Mirrors        npm / pip / conda / nvm / pyenv 镜像（中国区域自动启用）
  -Agents         Agents CLI（默认 $DefaultAgents）
  -Desktop        Claude / Codex 桌面端
  -Endpoint LIST  为 Agent 写入地址配置: claude,codex,gemini,opencode,pi,openai
  -Check          只读环境检查
  -Update         更新已安装的工具与 Agents
  -SelfUpdate     更新本脚本（快捷命令模式）
  -InstallShortcut 安装快捷命令 inst

选项:
  -AgentList LIST      $(($AgentTable | ForEach-Object { $_.Id }) -join ',') 或 all
  -AgentMethod M       auto | official | npm
  -BaseUrl URL         Agent API 地址（密钥用环境变量 INST_API_KEY 传入）
  -Model NAME          默认模型
  -Region R            auto | cn | global
  -MirrorPreset P      tuna | aliyun | ustc | tencent | huawei | official
  -NpmRegistry URL  -PipIndex URL  -SystemMirror ustc|URL  -ApplySystemMirror
  -GhProxy URL         GitHub 下载加速前缀
  -PythonVersion V     latest | 3.x | 3.x.y
  -DesktopApps LIST    claude,codex    -DesktopDir DIR   安装目录（Claude 安装后移动并留目录联接；Codex 为 MSIX 不支持）
  -Prefix DIR          缓存目录（默认 %LOCALAPPDATA%\inst）
  -Yes  -DryRun  -Quiet  -Version
"@
}

# ---------------------------------------------------------------- 入口
# 退出码写入 $script:InstExitCode，函数输出（版本号、帮助）直接进入管道。
function Invoke-InstMain {
  $script:InstExitCode = 0
  if ($Version) { $InstVersion; return }
  if ($Help) { Show-Usage; return }
  if ($AgentMethod -notin @('auto','official','npm')) { throw '-AgentMethod 只能是 auto、official 或 npm' }
  if ($Region -notin @('auto','cn','global')) { throw '-Region 只能是 auto、cn 或 global' }
  if ($GhProxy) { Assert-HttpsUrl $GhProxy 'GhProxy' }
  if ($OfficialAgents) { $script:Agents = $true; $script:AgentMethod = 'official' }
  if ($AgentPackages) { $script:Agents = $true }
  if ($BaseUrl -or $AnthropicBaseUrl -or $OpenAiBaseUrl -or $Endpoint) { $script:DoEndpoint = $true } else { $script:DoEndpoint = $false }
  if ($All) { $script:Node = $true; $script:Python = $true; $script:Mirrors = $true; $script:Agents = $true }
  $any = $Node -or $Python -or $Mirrors -or $Agents -or $Desktop -or $Check -or $Update -or $SelfUpdate -or $InstallShortcut -or $script:DoEndpoint
  if ($Menu -or -not $any) {
    if ([Environment]::UserInteractive -and -not $env:INST_NO_TTY -and -not [Console]::IsInputRedirected) { Show-MainMenu; return }
    Show-Usage; $script:InstExitCode = 2; return
  }
  if ($Check) { Show-Check; return }
  if ($SelfUpdate) { Update-Installer; return }
  Write-Inst "检测到 Windows $([Environment]::OSVersion.Version) $Arch，PowerShell $($PSVersionTable.PSVersion)"
  if ($InstallShortcut) { Install-Shortcut }
  if ($script:DoEndpoint) { Set-AgentEndpoints }
  if ($Mirrors) { Set-Mirrors }
  if ($Node) { Install-Node }
  if ($Python) { Install-Python }
  if ($Agents) { Install-Agents }
  if ($Desktop) { Install-Desktop }
  if ($Update) { Update-All }
  if ($DryRun) { Write-Inst '预览结束，未执行安装' } else { Write-Ok '所选步骤执行结束；新开终端使环境变量生效' }
}

if ($LibOnly -or $env:INST_LIB_ONLY -eq '1') { return }
$script:InstExitCode = 1
try { Invoke-InstMain } catch { Write-Fail "$_"; $script:InstExitCode = 1 }
# install.ps1 总是以 -File 在子进程中运行本脚本，这里 exit 不会关闭用户窗口；被直接 iex 时不 exit。
if ($MyInvocation.MyCommand.Path -and $script:InstExitCode -ne 0) { exit $script:InstExitCode }
