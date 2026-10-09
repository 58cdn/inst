# cgpu - watch NVIDIA GPU status in cmd.exe and PowerShell.
[CmdletBinding()]
param(
  [ValidateRange(1, 3600)][int]$Interval = 1,
  [switch]$Once
)

$ErrorActionPreference = 'Stop'
$command = Get-Command 'nvidia-smi' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
$exe = if ($command) { $command.Source } else { $null }
if (-not $exe -and $env:ProgramFiles) {
  $candidate = Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVSMI\nvidia-smi.exe'
  if (Test-Path -LiteralPath $candidate) { $exe = $candidate }
}
if (-not $exe) {
  [Console]::Error.WriteLine('[cgpu] nvidia-smi not found. Install the NVIDIA driver and make nvidia-smi available.')
  exit 1
}

do {
  if (-not $Once) {
    try { Clear-Host -ErrorAction Stop } catch { }
  }
  Write-Host ('[cgpu] {0}  |  refresh: {1}s  |  Ctrl+C to stop' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Interval)
  & $exe
  if ($LASTEXITCODE -ne 0) {
    [Console]::Error.WriteLine('[cgpu] nvidia-smi failed with exit code {0}.' -f $LASTEXITCODE)
    exit 1
  }
  if ($Once) { break }
  Start-Sleep -Seconds $Interval
} while ($true)
