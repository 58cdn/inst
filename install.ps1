# inst bootstrap for Windows PowerShell 5.1+ / PowerShell 7 (ASCII only, safe for `irm | iex`).
#   irm https://inst.linux.yun | iex    (PowerShell's User-Agent gets this file, /install.ps1)
#   & ([scriptblock]::Create((irm https://inst.linux.yun))) -All
# The real implementation is scripts/install-windows.ps1. It always runs in a child process so that
# `exit` inside it can never close the user's console, and so it gets a proper script scope.
$instBootstrapArgs = @($args)
# Empty under `irm | iex` and scriptblock invocation; set only when run as a file.
$instBootstrapSelf = $MyInvocation.MyCommand.Path

function Test-InstHttpsUrl([string]$Value) {
  $uri = $null
  return [Uri]::TryCreate($Value, [UriKind]::Absolute, [ref]$uri) -and $uri.Scheme -eq 'https' -and [bool]$uri.Host
}
function Get-InstMirrorUrls([object]$Manifest, [string]$Fallback) {
  $entries = @()
  if ($Manifest -is [Array]) { $entries = @($Manifest) }
  elseif ($Manifest -and $Manifest.mirrors) { $entries = @($Manifest.mirrors) }
  $urls = @(); $seen = @{}
  foreach ($entry in $entries) {
    $url = if ($entry -is [string]) { [string]$entry } else { [string]$entry.url }
    if (-not $url) { continue }
    $url = $url.Trim().TrimEnd('/')
    if (-not (Test-InstHttpsUrl $url) -or $seen.ContainsKey($url)) { continue }
    $seen[$url] = $true
    $urls += $url
  }
  $fallback = $Fallback.TrimEnd('/')
  if (Test-InstHttpsUrl $fallback -and -not $seen.ContainsKey($fallback)) { $urls += $fallback }
  return $urls
}
function Test-InstMirror([string]$Base, [int]$TimeoutSec) {
  $watch = [Diagnostics.Stopwatch]::StartNew()
  try {
    $response = Invoke-WebRequest -UseBasicParsing -Method Get -Uri ($Base.TrimEnd('/') + '/VERSION') -TimeoutSec $TimeoutSec -ErrorAction Stop
    $watch.Stop()
    $status = [int]$response.StatusCode
    if ($status -ge 200 -and $status -lt 400) {
      return [pscustomobject]@{ Url = $Base.TrimEnd('/'); LatencyMs = [math]::Round($watch.Elapsed.TotalMilliseconds, 3) }
    }
  } catch { }
  if ($watch.IsRunning) { $watch.Stop() }
  return $null
}
function Resolve-InstBaseUrl([string]$Fallback) {
  if ($env:INST_MIRROR_AUTO -eq '0') { return $Fallback }
  $timeout = 5; $parsed = 0
  if ([int]::TryParse([string]$env:INST_MIRROR_TIMEOUT, [ref]$parsed) -and $parsed -gt 0 -and $parsed -le 60) { $timeout = $parsed }
  try {
    $manifest = Invoke-RestMethod -UseBasicParsing -Uri ($Fallback.TrimEnd('/') + '/mirrors.json') -TimeoutSec $timeout -ErrorAction Stop
  } catch {
    Write-Host "[inst] mirror list unavailable; using default $Fallback"
    return $Fallback
  }
  $results = @(
    foreach ($url in (Get-InstMirrorUrls $manifest $Fallback)) {
      $result = Test-InstMirror $url $timeout
      if ($result) { $result }
    }
  )
  if ($results.Count) {
    $best = $results | Sort-Object LatencyMs | Select-Object -First 1
    Write-Host "[inst] selected mirror $($best.Url) (latency $($best.LatencyMs)ms)"
    return $best.Url
  }
  Write-Host "[inst] no reachable mirror; using default $Fallback"
  return $Fallback
}
if ($env:INST_BOOTSTRAP_LIB_ONLY -eq '1') { return }
& {
  param([object[]]$Forward, [string]$Self)
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

  $hostExe = (Get-Process -Id $PID).Path
  if (-not $hostExe) { $hostExe = 'powershell.exe' }
  $local = $null
  if ($Self) {
    $candidate = Join-Path (Split-Path -Parent $Self) 'scripts\install-windows.ps1'
    if (Test-Path -LiteralPath $candidate) { $local = $candidate }
  }

  $temp = $null
  try {
    if ($local) {
      if (-not $env:INST_INSTALLER_PATH) { $env:INST_INSTALLER_PATH = $local }
      $target = $local
    } else {
      $base = $env:INST_RAW_BASE_URL
      $explicitBase = [bool]$base
      if (-not $base) { $base = 'https://inst.linux.yun' }
      if (-not (Test-InstHttpsUrl $base)) { throw 'INST_RAW_BASE_URL must use HTTPS' }
      if (-not $explicitBase) { $base = Resolve-InstBaseUrl $base }
      $env:INST_RAW_BASE_URL = $base
      $env:INST_RUN_MODE = 'remote'
      try {
        $bytes = (New-Object Net.WebClient).DownloadData("$base/scripts/install-windows.ps1")
      } catch {
        if ($explicitBase -or $base -eq 'https://inst.linux.yun') { throw }
        Write-Host '[inst] selected mirror download failed; retrying default https://inst.linux.yun'
        $base = 'https://inst.linux.yun'
        $env:INST_RAW_BASE_URL = $base
        $bytes = (New-Object Net.WebClient).DownloadData("$base/scripts/install-windows.ps1")
      }
      $code = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
      $tokens = $null; $errors = $null
      [Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors) | Out-Null
      if ($errors.Count) { throw "downloaded installer failed to parse: $($errors[0])" }
      $temp = Join-Path ([IO.Path]::GetTempPath()) ("inst-" + [Guid]::NewGuid().ToString('N') + '.ps1')
      # Windows PowerShell 5.1 reads BOM-less files with the ANSI code page, so keep the BOM.
      [IO.File]::WriteAllText($temp, $code, (New-Object Text.UTF8Encoding $true))
      $target = $temp
    }
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $target)
    foreach ($item in $Forward) { $childArgs += [string]$item }
    & $hostExe @childArgs
    $global:LASTEXITCODE = $LASTEXITCODE
  } catch {
    Write-Host "[inst] $_" -ForegroundColor Red
    $global:LASTEXITCODE = 1
  } finally {
    if ($temp) { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
  }
} $instBootstrapArgs $instBootstrapSelf
$instBootstrapFile = $instBootstrapSelf
Remove-Variable instBootstrapArgs, instBootstrapSelf -ErrorAction SilentlyContinue
# Only a real `-File` run may exit; under iex that would close the user's console.
if ($instBootstrapFile -and $LASTEXITCODE) { exit $LASTEXITCODE }
