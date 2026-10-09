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
    if ([IO.File]::Exists($OutFile)) { [IO.File]::Replace($temp, $OutFile, [System.Management.Automation.Language.NullString]::Value) }
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
function Save-InstDownload([string]$Url, [string]$OutFile, [string]$Sha256 = '', $ResolvedUrl = $null) {
  # Optional [ref] output; a typed [ref] default rejects omitted arguments in PS5.1.
  if ($null -ne $ResolvedUrl -and $ResolvedUrl -isnot [System.Management.Automation.PSReference]) { throw 'ResolvedUrl must be a reference' }
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
