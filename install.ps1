# inst bootstrap for Windows PowerShell 5.1+ / PowerShell 7 (ASCII only, safe for `irm | iex`).
#   irm https://inst.linux.yun | iex    (PowerShell's User-Agent gets this file, /install.ps1)
#   & ([scriptblock]::Create((irm https://inst.linux.yun))) -All
# The real implementation is scripts/install-windows.ps1. It always runs in a child process so that
# `exit` inside it can never close the user's console, and so it gets a proper script scope.
$instBootstrapArgs = @($args)
# Empty under `irm | iex` and scriptblock invocation; set only when run as a file.
$instBootstrapSelf = $MyInvocation.MyCommand.Path
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
      if (-not $base) { $base = 'https://inst.linux.yun' }
      if (-not $base.StartsWith('https://')) { throw 'INST_RAW_BASE_URL must use HTTPS' }
      $env:INST_RAW_BASE_URL = $base
      $env:INST_RUN_MODE = 'remote'
      $bytes = (New-Object Net.WebClient).DownloadData("$base/scripts/install-windows.ps1")
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
