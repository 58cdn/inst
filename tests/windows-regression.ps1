$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$script = Join-Path $root 'scripts\install-windows.ps1'
$env:INST_NO_UPDATE_CHECK = '1'
$env:INST_NO_TTY = '1'
$env:INST_REGION = 'global'
# The child sets UTF-8 output; decode it the same way.
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$savedProfile = $env:USERPROFILE
$savedKey = $env:INST_API_KEY
function Invoke-Inst {
  $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script @args 2>&1 | Out-String
  [pscustomobject]@{ Code = $LASTEXITCODE; Text = $output }
}
function Assert-True([bool]$Condition, [string]$Message, $Result) {
  if (-not $Condition) { throw "$Message`n$($Result.Text)" }
}

# Bootstrap mirror selection is tested without starting the installer child process.
$env:INST_BOOTSTRAP_LIB_ONLY = '1'
. (Join-Path $root 'install.ps1')
Remove-Item Env:INST_BOOTSTRAP_LIB_ONLY -ErrorAction SilentlyContinue
function Invoke-RestMethod {
  [CmdletBinding()] param([string]$Uri, [switch]$UseBasicParsing, [int]$TimeoutSec)
  if ($env:TEST_MIRROR_MANIFEST_FAIL -eq '1') { throw 'simulated manifest failure' }
  return [pscustomobject]@{ mirrors = @(
    [pscustomobject]@{ url = 'https://mirror.slow.invalid' },
    [pscustomobject]@{ url = 'https://mirror.fast.invalid' },
    [pscustomobject]@{ url = 'https://inst.linux.yun' }
  ) }
}
function Test-InstMirror([string]$Base, [int]$TimeoutSec) {
  if ($env:TEST_MIRROR_ALL_FAIL -eq '1') { return $null }
  switch ($Base) {
    'https://mirror.slow.invalid' { return [pscustomobject]@{ Url = $Base; LatencyMs = 250 } }
    'https://mirror.fast.invalid' { return [pscustomobject]@{ Url = $Base; LatencyMs = 25 } }
    default { return [pscustomobject]@{ Url = $Base; LatencyMs = 100 } }
  }
}
$selection = Resolve-InstBaseUrl 'https://inst.linux.yun'
if ($selection -ne 'https://mirror.fast.invalid') { throw "PowerShell fast mirror selection failed: $selection" }
$env:TEST_MIRROR_ALL_FAIL = '1'
$selection = Resolve-InstBaseUrl 'https://inst.linux.yun'
if ($selection -ne 'https://inst.linux.yun') { throw "PowerShell all-mirror fallback failed: $selection" }
$env:TEST_MIRROR_MANIFEST_FAIL = '1'; Remove-Item Env:TEST_MIRROR_ALL_FAIL -ErrorAction SilentlyContinue
$selection = Resolve-InstBaseUrl 'https://inst.linux.yun'
if ($selection -ne 'https://inst.linux.yun') { throw "PowerShell manifest fallback failed: $selection" }
$env:INST_MIRROR_AUTO = '0'; Remove-Item Env:TEST_MIRROR_MANIFEST_FAIL -ErrorAction SilentlyContinue
$selection = Resolve-InstBaseUrl 'https://inst.linux.yun'
if ($selection -ne 'https://inst.linux.yun') { throw "PowerShell explicit auto-disable failed: $selection" }
foreach ($name in @('INST_MIRROR_AUTO','TEST_MIRROR_MANIFEST_FAIL')) { Remove-Item "Env:$name" -ErrorAction SilentlyContinue }
'PASS: PowerShell bootstrap mirror selection and fallbacks'

# Version, usage and argument validation
$r = Invoke-Inst -Version
$expected = (Get-Content -LiteralPath (Join-Path $root 'VERSION') -Raw).Trim()
Assert-True ($r.Code -eq 0 -and $r.Text.Trim() -eq $expected) "-Version should print $expected" $r
$r = Invoke-Inst
Assert-True ($r.Code -eq 2 -and $r.Text -match '-AgentList') 'no arguments without a console should print usage and exit 2' $r
$r = Invoke-Inst -Agents -AgentMethod bogus
Assert-True ($r.Code -ne 0 -and $r.Text -match 'AgentMethod') 'invalid agent method should fail' $r
$r = Invoke-Inst -Agents -AgentList nope -DryRun
Assert-True ($r.Code -ne 0 -and $r.Text -match 'nope') 'unknown agent should fail' $r
'PASS: version, usage and argument errors'

# Dry-run must not change PATH or create the prefix
$beforeUserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$probe = Join-Path $env:TEMP ('inst-' + [guid]::NewGuid().ToString('N'))
$r = Invoke-Inst -All -Desktop -DryRun -AgentList all -AgentMethod npm -Prefix $probe -DesktopDir $probe
Assert-True ($r.Code -eq 0) 'dry-run failed' $r
Assert-True (-not (Test-Path -LiteralPath $probe)) 'dry-run created the prefix directory' $r
Assert-True ([Environment]::GetEnvironmentVariable('Path', 'User') -ceq $beforeUserPath) 'dry-run changed user PATH' $r
foreach ($needle in @('Miniconda3-latest-Windows-', 'install --global @openai/codex', 'install --global @earendil-works/pi-coding-agent', 'x.ai/cli/install.ps1', 'hermes-agent.nousresearch.com/install.ps1 -SkipSetup', 'claude.ai/api/desktop/win32', '预览结束')) {
  Assert-True ($r.Text.Contains($needle)) "dry-run output is missing: $needle" $r
}
$r = Invoke-Inst -Agents -AgentList 'claude,codex' -DryRun
Assert-True ($r.Text.Contains('claude.ai/install.ps1') -and $r.Text.Contains('chatgpt.com/codex/install.ps1')) 'auto method should prefer official scripts outside cn' $r
$r = Invoke-Inst -Agents -AgentList claude -DryRun -Region cn
Assert-True ($r.Text.Contains('install --global @anthropic-ai/claude-code')) 'auto method should prefer npm in cn' $r
$r = Invoke-Inst -Desktop -DryRun -ClaudeDesktopUrl 'http://example.com/a.exe'
Assert-True ($r.Code -ne 0 -and $r.Text -match 'HTTPS') 'http desktop URL should be rejected' $r
'PASS: dry-run plans, agent method selection and HTTPS validation'

# Endpoint configuration merges into existing files (isolated USERPROFILE)
$home2 = Join-Path $env:TEMP ('inst-home-' + [guid]::NewGuid().ToString('N'))
try {
  New-Item -ItemType Directory -Force -Path (Join-Path $home2 '.claude'), (Join-Path $home2 '.codex') | Out-Null
  [IO.File]::WriteAllText((Join-Path $home2 '.claude\settings.json'), '{"theme":"dark","env":{"FOO":"1"}}')
  [IO.File]::WriteAllText((Join-Path $home2 '.codex\config.toml'), "model_provider = `"old`"`napproval_policy = `"never`"`n`n[model_providers.inst]`nbase_url = `"https://old`"`n`n[mcp_servers.x]`ncommand = `"x`"`n")
  $env:USERPROFILE = $home2
  $env:INST_API_KEY = 'sk-test'
  $r = Invoke-Inst -Endpoint 'claude,gemini,opencode,pi' -BaseUrl 'https://api.example.com/v1/' -Model m1
  Assert-True ($r.Code -eq 0) 'endpoint configuration failed' $r
  $claude = Get-Content -LiteralPath (Join-Path $home2 '.claude\settings.json') -Raw | ConvertFrom-Json
  Assert-True ($claude.theme -eq 'dark' -and $claude.env.FOO -eq '1' -and $claude.env.ANTHROPIC_BASE_URL -eq 'https://api.example.com/v1' -and $claude.env.ANTHROPIC_AUTH_TOKEN -eq 'sk-test') 'claude settings not merged' $r
  $gemini = Get-Content -LiteralPath (Join-Path $home2 '.gemini\.env') -Raw
  Assert-True ($gemini.Contains('GOOGLE_GEMINI_BASE_URL=https://api.example.com/v1') -and $gemini.Contains('GEMINI_API_KEY=sk-test')) 'gemini .env not written' $r
  $opencode = Get-Content -LiteralPath (Join-Path $home2 '.config\opencode\opencode.json') -Raw | ConvertFrom-Json
  Assert-True ($opencode.provider.inst.options.baseURL -eq 'https://api.example.com/v1' -and $opencode.model -eq 'inst/m1') 'opencode config not written' $r
  $pi = Get-Content -LiteralPath (Join-Path $home2 '.pi\agent\models.json') -Raw | ConvertFrom-Json
  Assert-True ($pi.providers.inst.baseUrl -eq 'https://api.example.com/v1' -and @($pi.providers.inst.models)[0].id -eq 'm1') 'pi models.json not written' $r
  # Codex without a key so the test never writes user environment variables
  $env:INST_API_KEY = ''
  $r = Invoke-Inst -Endpoint codex -BaseUrl 'https://api.example.com/v1'
  $toml = @(Get-Content -LiteralPath (Join-Path $home2 '.codex\config.toml'))
  Assert-True ($toml[0] -eq 'model_provider = "inst"') 'codex model_provider must be the first line' $r
  Assert-True (@($toml | Where-Object { $_ -eq '[model_providers.inst]' }).Count -eq 1) 'codex inst table duplicated' $r
  Assert-True (($toml -join "`n").Contains('approval_policy = "never"') -and ($toml -join "`n").Contains('[mcp_servers.x]') -and -not ($toml -join "`n").Contains('https://old')) 'codex config lost settings or kept old provider' $r
  $r = Invoke-Inst -Endpoint claude -BaseUrl 'http://api.example.com'
  Assert-True ($r.Code -ne 0) 'http endpoint should be rejected' $r
} finally {
  $env:USERPROFILE = $savedProfile
  $env:INST_API_KEY = $savedKey
  Remove-Item -LiteralPath $home2 -Recurse -Force -ErrorAction SilentlyContinue
}
'PASS: endpoint configuration merges existing files'
# The last installer run failed on purpose; don't pass its exit code on (CI exits with $LASTEXITCODE).
exit 0
