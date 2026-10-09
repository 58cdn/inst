# inst bootstrap for Windows PowerShell 5.1+ / PowerShell 7 (ASCII only, safe for `irm | iex`).
#   irm https://inst.linux.yun | iex    (PowerShell's User-Agent gets this file, /install.ps1)
#   & ([scriptblock]::Create((irm https://inst.linux.yun))) -All
# The real implementation is scripts/install-windows.ps1. It always runs in a child process so that
# `exit` inside it can never close the user's console, and so it gets a proper script scope.
$instBootstrapArgs = @($args)
# Empty under `irm | iex` and scriptblock invocation; set only when run as a file.
$instBootstrapSelf = $MyInvocation.MyCommand.Path

# BEGIN GENERATED DOWNLOAD
# Embedded into standalone entry points by tools/embed-download.mjs.
function Test-InstDownloadPrefix([string]$Url, [byte[]]$Bytes, [int]$Count, [string]$ContentType) {
  $text = [Text.Encoding]::UTF8.GetString($Bytes, 0, [Math]::Min($Count, 512))
  if ($ContentType -match '(?i)text/html|application/(json|problem\+json)' -or $text -match '(?i)<(!doctype\s+html|html|head|body)[\s>]') { throw 'unexpected error document' }
  $path = ([Uri]$Url).AbsolutePath
  if ($path -match '\.(zip|msix)$' -and ($Count -lt 4 -or [BitConverter]::ToString($Bytes,0,4) -ne '50-4B-03-04')) { throw 'invalid ZIP prefix' }
  if ($path -match '\.exe$' -and ($Count -lt 2 -or $Bytes[0] -ne 77 -or $Bytes[1] -ne 90)) { throw 'invalid EXE prefix' }
  if ($path -match '\.sh$' -and -not $text.StartsWith('#!')) { throw 'invalid script prefix' }
  if ($path -notmatch '\.(zip|msix|exe|sh|ps1|asc|cmd)$' -and $Count -lt 512) { throw 'unrecognized short response' }
  if ($path -match '\.cmd$' -and $text.TrimStart([char]0xFEFF) -notmatch '\A(?i:@echo[ \t]+off)(?:\r?\n|$)') { throw 'invalid CMD prefix' }
  if ($path -match '\.ps1$' -and -not $text.TrimStart([char]0xFEFF).StartsWith('#')) { throw 'invalid PowerShell prefix' }
}
function Wait-InstDownloadTask($Task, $Cancellation) {
  # Polling yields to PowerShell so Ctrl+C enters the caller's finally block.
  while (-not $Task.IsCompleted) { $Cancellation.Token.ThrowIfCancellationRequested(); Start-Sleep -Milliseconds 50 }
  return $Task.GetAwaiter().GetResult()
}
function New-InstDownloadClient {
  $handler = New-Object Net.Http.HttpClientHandler
  $handler.AllowAutoRedirect = $false
  $handler.UseCookies = $false
  return New-Object Net.Http.HttpClient($handler)
}
function Save-InstDownloadAttempt([string]$Url, [string]$OutFile, [string]$Sha256 = '', [int]$StartSeconds = 30, [int]$IdleSeconds = 120) {
  Add-Type -AssemblyName System.Net.Http
  $OutFile = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutFile)
  $uri = [Uri]$Url
  if ($uri.Scheme -ne 'https' -or $uri.UserInfo) { throw 'public HTTPS URL required' }
  $client = New-InstDownloadClient
  $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
  $cts = New-Object Threading.CancellationTokenSource
  $cts.CancelAfter([TimeSpan]::FromSeconds($StartSeconds))
  $temp = $OutFile + '.part.' + [Guid]::NewGuid().ToString('N')
  $response = $null; $stream = $null; $file = $null
  try {
    for ($redirect = 0; $redirect -le 5; $redirect++) {
      $request = New-Object Net.Http.HttpRequestMessage([Net.Http.HttpMethod]::Get, $uri)
      try { $response = Wait-InstDownloadTask ($client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cts.Token)) $cts }
      finally { $request.Dispose() }
      $status = [int]$response.StatusCode
      if ($status -in @(301,302,303,307,308)) {
        if ($redirect -eq 5 -or -not $response.Headers.Location) { throw 'redirect limit or missing location' }
        $uri = New-Object Uri($uri, $response.Headers.Location)
        if ($uri.Scheme -ne 'https' -or $uri.UserInfo) { throw 'unsafe redirect' }
        $response.Dispose(); $response = $null
        continue
      }
      if ($status -ne 200) { throw "HTTP $status" }
      break
    }
    $stream = Wait-InstDownloadTask ($response.Content.ReadAsStreamAsync()) $cts
    $file = [IO.File]::Open($temp, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $buffer = New-Object byte[] 65536
    $prefix = New-Object byte[] 512
    $prefixCount = 0; $total = [long]0; $started = $false
    while ($true) {
      $count = Wait-InstDownloadTask ($stream.ReadAsync($buffer,0,$buffer.Length,$cts.Token)) $cts
      if ($cts.IsCancellationRequested) { throw 'download deadline exceeded' }
      if ($count -eq 0) { break }
      $copy = [Math]::Min(512 - $prefixCount, $count)
      if ($copy -gt 0) { [Array]::Copy($buffer,0,$prefix,$prefixCount,$copy); $prefixCount += $copy }
      $file.Write($buffer,0,$count); $total += $count
      if (-not $started -and $prefixCount -eq 512) {
        Test-InstDownloadPrefix $Url $prefix $prefixCount ([string]$response.Content.Headers.ContentType)
        $started = $true
      }
      if ($started) { $cts.CancelAfter([TimeSpan]::FromSeconds($IdleSeconds)) }
    }
    if ($total -eq 0) { throw 'empty response' }
    Test-InstDownloadPrefix $Url $prefix $prefixCount ([string]$response.Content.Headers.ContentType)
    if ($null -ne $response.Content.Headers.ContentLength -and $total -ne $response.Content.Headers.ContentLength) { throw 'incomplete response' }
    $file.Dispose(); $file = $null
    if ($Sha256 -and (Get-FileHash -LiteralPath $temp -Algorithm SHA256).Hash -ne $Sha256) { throw 'SHA256 mismatch' }
    if ([IO.File]::Exists($OutFile)) { [IO.File]::Replace($temp, $OutFile, $null) }
    else { [IO.File]::Move($temp, $OutFile) }
  } catch [OperationCanceledException] {
    throw 'download start/no-progress deadline exceeded'
  } finally {
    $cts.Cancel()
    if ($file) { $file.Dispose() }
    if ($stream) { $stream.Dispose() }
    if ($response) { $response.Dispose() }
    $client.Dispose(); $cts.Dispose()
    if (Test-Path -LiteralPath $temp) { Remove-Item -LiteralPath $temp -Force }
  }
}
function Get-InstDownloadCandidates([string]$Url, [string]$Sha256 = '') {
  $Url
  $official = 'https://inst.linux.yun/'
  $github = 'https://raw.githubusercontent.com/58cdn/inst/master/'
  foreach ($path in @('scripts/install-unix.sh','scripts/install-windows.ps1','install.sh','install.ps1')) {
    if ($env:INST_RAW_BASE_URL -or $env:INST_MIRROR_AUTO -eq '0') { continue }
    if ($Url -ceq ($official + $path)) { $github + $path }
    if ($Url -ceq ($github + $path)) { $official + $path }
  }
  if ($Sha256 -and $Url -cmatch '^https://(repo\.anaconda\.com/miniconda|mirrors\.tuna\.tsinghua\.edu\.cn/anaconda/miniconda)/(Miniconda3-[a-zA-Z0-9._-]+)$') {
    $name = $Matches[2]
    foreach ($base in @('https://repo.anaconda.com/miniconda/','https://mirrors.tuna.tsinghua.edu.cn/anaconda/miniconda/')) {
      if (($base + $name) -cne $Url) { $base + $name }
    }
  }
}
function Save-InstDownload([string]$Url, [string]$OutFile, [string]$Sha256 = '', [ref]$ResolvedUrl = $null) {
  $failures = @(); $index = 0
  foreach ($candidate in (Get-InstDownloadCandidates $Url $Sha256)) {
    $index++
    try {
      Save-InstDownloadAttempt $candidate $OutFile $Sha256
      if ($ResolvedUrl) { $ResolvedUrl.Value = $candidate }
      return
    }
    catch [Management.Automation.PipelineStoppedException] { throw }
    catch {
      $reason = "candidate ${index}: $($_.Exception.Message)"
      $failures += $reason
      Write-Warning $reason
    }
  }
  throw ('download candidates exhausted: ' + ($failures -join '; '))
}
# END GENERATED DOWNLOAD

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
# A child installer cannot update the parent process; refresh the invoking PowerShell
# after it exits, including the irm | iex entry point. Preserve custom process PATH entries.
function Refresh-InstCallerEnvironment {
  foreach ($name in @('NVM_HOME','NVM_SYMLINK','PYENV','PYENV_ROOT','PYENV_HOME')) {
    $value = [Environment]::GetEnvironmentVariable($name, 'User')
    if (-not $value) { $value = [Environment]::GetEnvironmentVariable($name, 'Machine') }
    if ($value) { [Environment]::SetEnvironmentVariable($name, $value, 'Process') }
  }
  $parts = @($env:Path, [Environment]::GetEnvironmentVariable('Path','User'), [Environment]::GetEnvironmentVariable('Path','Machine'))
  $unique = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
  $paths = @()
  foreach ($part in ($parts -join ';').Split(';')) {
    if (-not $part.Trim()) { continue }
    $expanded = [Environment]::ExpandEnvironmentVariables($part.Trim())
    if ($unique.Add($expanded.TrimEnd('\'))) { $paths += $expanded }
  }
  $env:Path = ($paths -join ';')
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
      $env:INST_RUN_MODE = 'remote'
      $temp = Join-Path ([IO.Path]::GetTempPath()) ("inst-" + [Guid]::NewGuid().ToString('N') + '.ps1')
      $downloadedUrl = ''
      try {
        Save-InstDownload "$base/scripts/install-windows.ps1" $temp '' ([ref]$downloadedUrl)
      } catch [Management.Automation.PipelineStoppedException] { throw } catch {
        if ($explicitBase -or $base -in @('https://inst.linux.yun','https://raw.githubusercontent.com/58cdn/inst/master')) { throw }
        Write-Host '[inst] selected mirror download failed; retrying default https://inst.linux.yun'
        $base = 'https://inst.linux.yun'
        Save-InstDownload "$base/scripts/install-windows.ps1" $temp '' ([ref]$downloadedUrl)
      }
      $base = $downloadedUrl.Substring(0, $downloadedUrl.Length - '/scripts/install-windows.ps1'.Length)
      if ($explicitBase) { $env:INST_RAW_BASE_URL = $base }
      else { $env:INST_SELECTED_BASE_URL = $base }
      $bytes = [IO.File]::ReadAllBytes($temp)
      $code = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
      $tokens = $null; $errors = $null
      [Management.Automation.Language.Parser]::ParseInput($code, [ref]$tokens, [ref]$errors) | Out-Null
      if ($errors.Count) { throw "downloaded installer failed to parse: $($errors[0])" }
      # Windows PowerShell 5.1 reads BOM-less files with the ANSI code page, so keep the BOM.
      [IO.File]::WriteAllText($temp, $code, (New-Object Text.UTF8Encoding $true))
      $target = $temp
    }
    $childArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $target)
    foreach ($item in $Forward) { $childArgs += [string]$item }
    & $hostExe @childArgs
    $global:LASTEXITCODE = $LASTEXITCODE
    $readOnly = @($Forward | Where-Object { $_ -in @('-Check','-Version','-Help','-DryRun') }).Count -gt 0
    if ($global:LASTEXITCODE -eq 0 -and -not $readOnly) {
      try { Refresh-InstCallerEnvironment }
      catch { Write-Host "[inst] parent shell environment refresh failed: $_" -ForegroundColor Yellow }
    }
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
