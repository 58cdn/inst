@echo off
rem inst entry for cmd.exe:  curl -fsSLo inst.cmd https://inst.linux.yun/install.cmd ^&^& inst.cmd
setlocal
set "INST_LAUNCHER=cmd"
if defined INST_RAW_BASE_URL (set "INST_BOOTSTRAP_BASE=%INST_RAW_BASE_URL%") else (set "INST_BOOTSTRAP_BASE=https://inst.linux.yun")
if not exist "%~dp0install.ps1" goto remote
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" %*
exit /b %errorlevel%
:remote
set "INST_BOOTSTRAP_FILE=%TEMP%\inst-%RANDOM%-%RANDOM%.ps1"
rem Small outer bootstrap: 30s total budget per candidate; payloads have no total cap.
powershell.exe -NoProfile -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Net.Http; $urls=@($env:INST_BOOTSTRAP_BASE + '/install.ps1'); if (-not $env:INST_RAW_BASE_URL -and $env:INST_MIRROR_AUTO -ne '0') { $urls+='https://raw.githubusercontent.com/58cdn/inst/master/install.ps1' }; $ok=$false; foreach ($url in $urls) { $h=New-Object Net.Http.HttpClientHandler; $h.AllowAutoRedirect=$false; $h.UseCookies=$false; $c=New-Object Net.Http.HttpClient($h); $cts=New-Object Threading.CancellationTokenSource; $cts.CancelAfter(30000); $r=$null; try { $uri=[Uri]$url; for ($i=0; $i -le 5; $i++) { if ($uri.Scheme -ne 'https' -or $uri.UserInfo) { throw 'public HTTPS URL required' }; $r=$c.GetAsync($uri,$cts.Token).GetAwaiter().GetResult(); if ([int]$r.StatusCode -in @(301,302,303,307,308)) { if ($i -eq 5 -or -not $r.Headers.Location) { throw 'invalid redirect' }; $uri=New-Object Uri($uri,$r.Headers.Location); $r.Dispose(); $r=$null; continue }; if ([int]$r.StatusCode -ne 200) { throw ('HTTP '+[int]$r.StatusCode) }; break }; $code=$r.Content.ReadAsStringAsync().GetAwaiter().GetResult(); if (-not $code.StartsWith('#')) { throw 'invalid bootstrap prefix' }; $t=$null; $e=$null; [Management.Automation.Language.Parser]::ParseInput($code,[ref]$t,[ref]$e) | Out-Null; if ($e.Count) { throw 'invalid bootstrap syntax' }; [IO.File]::WriteAllText($env:INST_BOOTSTRAP_FILE,$code); $ok=$true; break } catch { Write-Warning $_.Exception.Message } finally { $cts.Cancel(); if ($r) { $r.Dispose() }; $c.Dispose(); $cts.Dispose() } }; if (-not $ok) { exit 1 }"
if errorlevel 1 goto failed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INST_BOOTSTRAP_FILE%" %*
set "INST_RESULT=%errorlevel%"
del "%INST_BOOTSTRAP_FILE%"
exit /b %INST_RESULT%

:failed
del "%INST_BOOTSTRAP_FILE%" 2>nul
exit /b 1
