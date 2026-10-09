$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script = Join-Path $root 'scripts\cgpu.ps1'
$cmd = Join-Path $root 'scripts\cgpu.cmd'
$installer = Join-Path $root 'scripts\install-windows.ps1'
$oldPath = $env:Path
$temp = Join-Path ([IO.Path]::GetTempPath()) ('cgpu-test-' + [guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Force -Path $temp | Out-Null
  [IO.File]::WriteAllText((Join-Path $temp 'nvidia-smi.cmd'), "@echo off`r`necho CGPU_TEST_GPU`r`nexit /b 0`r`n")
  $env:Path = "$temp;$oldPath"
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Once 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0 -or $output -notmatch 'CGPU_TEST_GPU') { throw "cgpu.ps1 -Once failed: $output" }
  $output = & cmd.exe /d /c ('"{0}" -Once' -f $cmd) 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0 -or $output -notmatch 'CGPU_TEST_GPU') { throw "cgpu.cmd -Once failed: $output" }

  # PowerShell 5.1 treats native stderr as an error record with Stop enabled.
  $ErrorActionPreference = 'Continue'
  try {
    $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script -Interval 0 -Once 2>&1 | Out-String
    $invalidIntervalExit = $LASTEXITCODE
  } finally {
    $ErrorActionPreference = 'Stop'
  }
  if ($invalidIntervalExit -eq 0) { throw 'cgpu should reject interval 0' }

  $env:INST_NO_TTY = '1'
  $env:INST_NO_UPDATE_CHECK = '1'
  $beforeUserPath = [Environment]::GetEnvironmentVariable('Path','User')
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -Cgpu -DryRun 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0 -or $output -notmatch 'cgpu.ps1' -or $output -notmatch 'cgpu.cmd' -or $output -notmatch 'cgpu.md') {
    throw "inst -Cgpu -DryRun failed: $output"
  }
  if ([Environment]::GetEnvironmentVariable('Path','User') -cne $beforeUserPath) { throw 'cgpu dry-run changed the user PATH' }
  'PASS: cgpu PowerShell, cmd launcher, argument validation and install dry-run'
} finally {
  $env:Path = $oldPath
  Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
}
