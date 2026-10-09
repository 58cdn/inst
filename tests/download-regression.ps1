$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../scripts/lib/download.ps1')
Add-Type -AssemblyName System.Net.Http
$compile = @{}
if ($PSVersionTable.PSVersion.Major -le 5) { $compile.ReferencedAssemblies = 'System.Net.Http' }
Add-Type @compile -TypeDefinition @'
using System;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;
public class InstTestHandler : HttpMessageHandler {
  public static string Mode;
  public static int Calls;
  public static string FixtureRoot;
  public static byte[] BootstrapBody;
  protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct) {
    Calls++;
    if (Mode == "bootstrap") {
      if (req.RequestUri.Host == "inst.linux.yun") return new HttpResponseMessage(HttpStatusCode.InternalServerError);
      return new HttpResponseMessage(HttpStatusCode.OK) { Content = new ByteArrayContent(BootstrapBody) };
    }
    if (Mode == "fixture") return new HttpResponseMessage(HttpStatusCode.OK) {
      Content = new ByteArrayContent(File.ReadAllBytes(Path.Combine(FixtureRoot, Path.GetFileName(req.RequestUri.AbsolutePath))))
    };
    if (Mode == "headers") await Task.Delay(5000, ct);
    if (Mode == "redirect") {
      await Task.Delay(600, ct);
      var r = new HttpResponseMessage(HttpStatusCode.Redirect);
      r.Headers.Location = new Uri("https://example.org/again.sh"); return r;
    }
    if (Mode == "downgrade") {
      var r = new HttpResponseMessage(HttpStatusCode.Redirect);
      r.Headers.Location = new Uri("http://example.org/a.sh"); return r;
    }
    return new HttpResponseMessage(Mode == "error" ? HttpStatusCode.InternalServerError : HttpStatusCode.OK) {
      Content = new StreamContent(new InstTestStream(Mode))
    };
  }
}
public class InstTestStream : Stream {
  string mode; int reads;
  public InstTestStream(string mode) { this.mode = mode; }
  public override async Task<int> ReadAsync(byte[] b, int offset, int count, CancellationToken ct) {
    reads++;
    if (mode == "no-data" || (mode == "tiny" && reads > 1) || (mode == "stall" && reads > 1)) await Task.Delay(5000,ct);
    if (mode == "empty" || (mode != "slow" && reads > 1) || reads > 8) return 0;
    if (mode == "slow") await Task.Delay(400,ct);
    var data = System.Text.Encoding.UTF8.GetBytes(mode == "html" ? "<html>oops</html>" : "#!/bin/sh\n" + new string('#', 1024));
    int size = mode == "tiny" ? 1 : data.Length;
    Array.Copy(data,0,b,offset,size); return size;
  }
  public override bool CanRead { get { return true; } }
  public override bool CanSeek { get { return false; } }
  public override bool CanWrite { get { return false; } }
  public override long Length { get { throw new NotSupportedException(); } }
  public override long Position { get { throw new NotSupportedException(); } set { throw new NotSupportedException(); } }
  public override int Read(byte[] b,int o,int c) { return ReadAsync(b,o,c,CancellationToken.None).GetAwaiter().GetResult(); }
  public override void Flush() { }
  public override long Seek(long o,SeekOrigin s) { throw new NotSupportedException(); }
  public override void SetLength(long l) { throw new NotSupportedException(); }
  public override void Write(byte[] b,int o,int c) { throw new NotSupportedException(); }
}
'@
function New-InstDownloadClient { return New-Object Net.Http.HttpClient((New-Object InstTestHandler)) }
$dir = Join-Path ([IO.Path]::GetTempPath()) ('inst-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $dir | Out-Null
try {
  $out = Join-Path $dir 'out'
  foreach ($mode in @('ok','slow','headers','redirect','downgrade','error','html','empty','tiny','no-data','stall','checksum')) {
    [InstTestHandler]::Mode = $mode; [InstTestHandler]::Calls = 0
    [IO.File]::WriteAllText($out,'original')
    $success = $false; $watch = [Diagnostics.Stopwatch]::StartNew()
    $digest = if ($mode -eq 'checksum') { '0' * 64 } else { '' }
    try { Save-InstDownloadAttempt 'https://example.org/a.sh' $out $digest 2 2; $success = $true }
    catch { Write-Host "$mode : $($_.Exception.Message)" }
    if ($success -ne ($mode -in @('ok','slow'))) { throw "unexpected result: $mode" }
    if (-not $success -and [IO.File]::ReadAllText($out) -ne 'original') { throw "replaced target: $mode" }
    if (@(Get-ChildItem $dir -Filter '*.part.*').Count) { throw "leaked temporary file: $mode" }
    if ($mode -in @('headers','redirect','tiny','no-data') -and $watch.Elapsed.TotalSeconds -gt 3.5) { throw "deadline reset: $mode" }
    if ($mode -eq 'slow' -and $watch.Elapsed.TotalSeconds -lt 3) { throw 'slow download was not exercised' }
    Write-Host "PASS: $mode"
  }
  # File.Replace must fail safely if an existing destination denies delete/replace.
  [InstTestHandler]::Mode = 'ok'
  [IO.File]::WriteAllText($out,'locked original')
  $lock = [IO.File]::Open($out, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
  $failed = $false
  try { Save-InstDownloadAttempt 'https://example.org/a.sh' $out }
  catch { $failed = $true }
  finally { $lock.Dispose() }
  if (-not $failed -or [IO.File]::ReadAllText($out) -ne 'locked original') { throw 'replacement failure lost original' }
  if (@(Get-ChildItem $dir -Filter '*.part.*').Count) { throw 'replacement failure leaked temporary file' }
  Write-Host 'PASS: locked destination survives replacement failure'
  # The real remote cgpu.cmd is 248 bytes: accept its CMD header, not arbitrary short bodies.
  [InstTestHandler]::Mode = 'fixture'
  [InstTestHandler]::FixtureRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../scripts'))
  Save-InstDownloadAttempt 'https://inst.linux.yun/scripts/cgpu.cmd' $out
  if ((Get-FileHash $out).Hash -ne (Get-FileHash (Join-Path ([InstTestHandler]::FixtureRoot) 'cgpu.cmd')).Hash) { throw 'small remote CMD changed' }
  [InstTestHandler]::Mode = 'ok'
  $rejected = $false
  try { Save-InstDownloadAttempt 'https://inst.linux.yun/scripts/cgpu.cmd' $out }
  catch { $rejected = $_.Exception.Message -match 'invalid CMD prefix' }
  if (-not $rejected) { throw 'CMD accepted a non-CMD body' }

  # Exercise actual Install-Cgpu with no adjacent assets, a real HttpClient, and isolated writes.
  $remote = Join-Path $dir 'remote'; New-Item -ItemType Directory $remote | Out-Null
  $remoteInstaller = Join-Path $remote 'install-windows.ps1'
  Copy-Item (Join-Path $PSScriptRoot '../scripts/install-windows.ps1') $remoteInstaller
  $savedProfile = $env:USERPROFILE
  $savedRaw = $env:INST_RAW_BASE_URL; $savedSelected = $env:INST_SELECTED_BASE_URL
  $env:USERPROFILE = $remote; $env:INST_RAW_BASE_URL = $null
  $env:INST_SELECTED_BASE_URL = 'https://inst.linux.yun'
  [InstTestHandler]::Mode = 'fixture'; [InstTestHandler]::Calls = 0
  $runner = [PowerShell]::Create()
  try {
    $null = $runner.AddScript({ param($Installer)
      $ErrorActionPreference = 'Stop'
      . $Installer -LibOnly
      function New-InstDownloadClient { return New-Object Net.Http.HttpClient((New-Object InstTestHandler)) }
      function Add-UserPath { param($Path,[switch]$Force) }
      if ($InstBase -ne 'https://inst.linux.yun') { throw 'automatic base lost' }
      if (@(Get-InstDownloadCandidates ($InstBase + '/scripts/install-windows.ps1')).Count -ne 2) { throw 'automatic base disabled self-update fallback' }
      Install-Cgpu
    }).AddArgument($remoteInstaller)
    $null = $runner.Invoke()
    if ($runner.HadErrors) { throw ($runner.Streams.Error | Out-String) }
    if ([InstTestHandler]::Calls -ne 3) { throw 'remote cgpu downloads were not exercised' }
    foreach ($name in @('cgpu.ps1','cgpu.cmd','cgpu.md')) {
      if ((Get-FileHash (Join-Path $remote ('.command/' + $name))).Hash -ne (Get-FileHash (Join-Path ([InstTestHandler]::FixtureRoot) $name)).Hash) { throw "remote cgpu mismatch: $name" }
    }
    $env:INST_RAW_BASE_URL = 'https://inst.linux.yun'
    if (@(Get-InstDownloadCandidates 'https://inst.linux.yun/scripts/install-windows.ps1').Count -ne 1) { throw 'explicit override lost' }
  } finally {
    $runner.Dispose(); $env:USERPROFILE = $savedProfile
    $env:INST_RAW_BASE_URL = $savedRaw; $env:INST_SELECTED_BASE_URL = $savedSelected
  }
  Write-Host 'PASS: real small CMD, remote Install-Cgpu, automatic self-update fallback and explicit override'
  # Full remote bootstrap: first official source fails, second source launches a child.
  $bootstrap = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../install.ps1'))
  $bootstrap = $bootstrap.Replace('return New-Object Net.Http.HttpClient($handler)', 'return New-Object Net.Http.HttpClient((New-Object InstTestHandler))')
  $bootstrap = $bootstrap.Replace("if (`$env:INST_BOOTSTRAP_LIB_ONLY -eq '1')", "function Resolve-InstBaseUrl { return 'https://inst.linux.yun' }; if (`$env:INST_BOOTSTRAP_LIB_ONLY -eq '1')")
  $child = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../scripts/lib/download.ps1')) + @'

if ($env:INST_RAW_BASE_URL) { throw 'automatic selection became explicit' }
if ($env:INST_SELECTED_BASE_URL -ne 'https://raw.githubusercontent.com/58cdn/inst/master') { throw 'lost successful source' }
if (@(Get-InstDownloadCandidates ($env:INST_SELECTED_BASE_URL + '/scripts/install-windows.ps1')).Count -ne 2) { throw 'self-update fallback disabled' }
Write-Output 'bootstrap-child-ok'
'@
  [InstTestHandler]::BootstrapBody = [Text.Encoding]::UTF8.GetBytes($child)
  [InstTestHandler]::Mode = 'bootstrap'; [InstTestHandler]::Calls = 0
  $savedRaw = $env:INST_RAW_BASE_URL; $savedSelected = $env:INST_SELECTED_BASE_URL
  $savedAuto = $env:INST_MIRROR_AUTO; $savedMode = $env:INST_RUN_MODE
  $env:INST_RAW_BASE_URL = $null; $env:INST_SELECTED_BASE_URL = $null; $env:INST_MIRROR_AUTO = $null
  $runner = [PowerShell]::Create()
  try {
    $null = $runner.AddScript({ param($Code) & ([scriptblock]::Create($Code)) -Version }).AddArgument($bootstrap)
    $result = $runner.Invoke() | Out-String
    if ($runner.HadErrors -or $result -notmatch 'bootstrap-child-ok' -or [InstTestHandler]::Calls -ne 2) { throw "remote bootstrap failed: $result $($runner.Streams.Error | Out-String)" }
  } finally {
    $runner.Dispose(); $env:INST_RAW_BASE_URL = $savedRaw; $env:INST_SELECTED_BASE_URL = $savedSelected
    $env:INST_MIRROR_AUTO = $savedAuto; $env:INST_RUN_MODE = $savedMode
  }
  Write-Host 'PASS: full bootstrap retains actual successful base and self-update fallback'

  # Official script execution must preserve UTF-8 without a BOM on Windows PowerShell 5.1.
  $fixtures = Join-Path $dir 'official'; New-Item -ItemType Directory $fixtures | Out-Null
  $value = [string][char]0x4e2d + [char]0x6587
  $unicodeCode = "# UTF-8 fixture`n`$value = '$value'`nif (`$value -cne ([string][char]0x4e2d + [char]0x6587)) { exit 9 }`n[IO.File]::WriteAllText(`$args[0], `$value)"
  [IO.File]::WriteAllText((Join-Path $fixtures 'unicode.ps1'), $unicodeCode, (New-Object Text.UTF8Encoding $false))
  [IO.File]::WriteAllBytes((Join-Path $fixtures 'invalid.ps1'), [byte[]](35,10,255))
  [InstTestHandler]::Mode = 'fixture'; [InstTestHandler]::FixtureRoot = $fixtures
  $runner = [PowerShell]::Create()
  try {
    $null = $runner.AddScript({ param($Installer,$Target)
      $ErrorActionPreference = 'Stop'
      . $Installer -LibOnly
      function New-InstDownloadClient { return New-Object Net.Http.HttpClient((New-Object InstTestHandler)) }
      function Refresh-ProcessEnvironment { }
      Invoke-OfficialPs1 'https://example.org/unicode.ps1' @($Target)
      Write-Output 'official-script-validated'
    }).AddArgument($remoteInstaller).AddArgument($out)
    $result = $runner.Invoke() | Out-String
    $actual = [IO.File]::ReadAllText($out)
    Write-Host "Unicode success: HadErrors=$($runner.HadErrors), UTF8=$([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($actual)))"
    if ($runner.HadErrors -or $result -notmatch 'official-script-validated' -or $actual -cne $value) {
      throw "official UTF-8 execution failed: result=$result bytes=$([BitConverter]::ToString([Text.Encoding]::UTF8.GetBytes($actual))) $($runner.Streams.Error | Out-String)"
    }
  } finally { $runner.Dispose() }
  # A separate runspace isolates the expected decoder failure from the success assertion.
  $runner = [PowerShell]::Create()
  try {
    $null = $runner.AddScript({ param($Installer,$Target)
      $ErrorActionPreference = 'Stop'
      . $Installer -LibOnly
      function New-InstDownloadClient { return New-Object Net.Http.HttpClient((New-Object InstTestHandler)) }
      function Refresh-ProcessEnvironment { }
      $rejected = $false
      try { Invoke-OfficialPs1 'https://example.org/invalid.ps1' @($Target) }
      catch {
        $cause = $_.Exception
        while ($cause.InnerException) { $cause = $cause.InnerException }
        $rejected = $cause -is [Text.DecoderFallbackException]
      }
      if (-not $rejected) { throw 'invalid UTF-8 was not rejected by the strict decoder' }
      Write-Output 'invalid-utf8-rejected'
    }).AddArgument($remoteInstaller).AddArgument($out)
    $result = $runner.Invoke() | Out-String
    Write-Host "Unicode rejection: HadErrors=$($runner.HadErrors), completed=$($result -match 'invalid-utf8-rejected')"
    if ($result -notmatch 'invalid-utf8-rejected' -or [IO.File]::ReadAllText($out) -cne $value) { throw "UTF-8 rejection failed: $result $($runner.Streams.Error | Out-String)" }
  } finally { $runner.Dispose() }
  Write-Host 'PASS: official Unicode script runs unchanged in PS5.1; invalid UTF-8 rejected'
  # Stop a running PowerShell pipeline (Ctrl+C equivalent) and verify finally cleanup.
  [InstTestHandler]::Mode = 'no-data'
  $runner = [PowerShell]::Create()
  $source = Join-Path $PSScriptRoot '../scripts/lib/download.ps1'
  $null = $runner.AddScript({ param($Source,$Target)
    . $Source
    function New-InstDownloadClient { return New-Object Net.Http.HttpClient((New-Object InstTestHandler)) }
    Save-InstDownloadAttempt 'https://example.org/a.sh' $Target '' 30 120
  }).AddArgument($source).AddArgument($out)
  $async = $runner.BeginInvoke()
  Start-Sleep -Milliseconds 500
  $runner.Stop()
  try { $runner.EndInvoke($async) } catch { }
  $runner.Dispose()
  if (@(Get-ChildItem $dir -Filter '*.part.*').Count) { throw 'cancelled pipeline leaked temporary file' }
  Write-Host 'PASS: cancellation cleanup'
  foreach ($url in @('https://example.org/a.sh','https://inst.linux.yun/scripts/install-unix.sh?token=secret','https://u:p@inst.linux.yun/scripts/install-unix.sh')) {
    if (@(Get-InstDownloadCandidates $url).Count -ne 1) { throw 'unsafe mirror mapping' }
  }
  # Parse and execute the CMD outer bootstrap in an isolated runspace with HTTP mocked.
  $cmd = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../install.cmd'))
  $cmdCode = [regex]::Match($cmd, '(?m)^powershell.exe -NoProfile -Command "(.*)"\r?$').Groups[1].Value
  $tokens = $null; $errors = $null
  [Management.Automation.Language.Parser]::ParseInput($cmdCode,[ref]$tokens,[ref]$errors) | Out-Null
  if (-not $cmdCode -or $errors.Count) { throw 'CMD bootstrap parse failed' }
  $cmdCode = $cmdCode.Replace('$c=New-Object Net.Http.HttpClient($h)', '$c=New-Object Net.Http.HttpClient((New-Object InstTestHandler))')
  $savedBase = $env:INST_BOOTSTRAP_BASE; $savedFile = $env:INST_BOOTSTRAP_FILE
  $env:INST_BOOTSTRAP_BASE = 'https://inst.linux.yun'; $env:INST_BOOTSTRAP_FILE = $out
  try {
    foreach ($mode in @('ok','error')) {
      Remove-Item -LiteralPath $out -Force -ErrorAction SilentlyContinue
      [InstTestHandler]::Mode = $mode; [InstTestHandler]::Calls = 0
      $runner = [PowerShell]::Create()
      $null = $runner.AddScript($cmdCode)
      $null = $runner.Invoke()
      $diagnostics = ($runner.Streams.Warning | Out-String) + ($runner.Streams.Error | Out-String)
      $runner.Dispose()
      if ((Test-Path -LiteralPath $out) -ne ($mode -eq 'ok')) { throw "CMD bootstrap result: $mode $diagnostics" }
      if ($mode -eq 'error' -and [InstTestHandler]::Calls -ne 2) { throw 'CMD bootstrap bounded fallback failed' }
    }
  } finally { $env:INST_BOOTSTRAP_BASE = $savedBase; $env:INST_BOOTSTRAP_FILE = $savedFile }
  Write-Host 'PASS: CMD bootstrap no-curl path, syntax and bounded fallback'
  $script:calls = 0
  function Save-InstDownloadAttempt { param($Url,$OutFile,$Sha256); $script:calls++; if ($script:calls -eq 1) { throw 'timeout' }; [IO.File]::WriteAllText($OutFile,'valid') }
  Save-InstDownload 'https://inst.linux.yun/scripts/install-unix.sh' $out
  if ($script:calls -ne 2 -or [IO.File]::ReadAllText($out) -ne 'valid') { throw 'mirror success failed' }
  $script:calls = 0
  function Save-InstDownloadAttempt { $script:calls++; throw 'SHA256 mismatch' }
  $exhausted = $false
  try { Save-InstDownload 'https://inst.linux.yun/scripts/install-unix.sh' $out }
  catch { $exhausted = $_.Exception.Message -match 'exhausted.*SHA256 mismatch.*SHA256 mismatch' }
  if (-not $exhausted -or $script:calls -ne 2) { throw 'bounded exhaustion/reasons failed' }
  Write-Host 'PASS: mirror policy, success and exhaustion'
} finally { Remove-Item -LiteralPath $dir -Recurse -Force }
