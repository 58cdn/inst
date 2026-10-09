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
  protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage req, CancellationToken ct) {
    Calls++;
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
