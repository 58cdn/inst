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
rem This small outer bootstrap has a 30s total cap; payload downloads have no total cap.
curl.exe --proto "=https" --proto-redir "=https" -fsSL --retry 0 --connect-timeout 20 --max-time 30 --max-redirs 5 "%INST_BOOTSTRAP_BASE%/install.ps1" -o "%INST_BOOTSTRAP_FILE%"
if not errorlevel 1 goto validate
if defined INST_RAW_BASE_URL goto failed
curl.exe --proto "=https" --proto-redir "=https" -fsSL --retry 0 --connect-timeout 20 --max-time 30 --max-redirs 5 "https://raw.githubusercontent.com/58cdn/inst/master/install.ps1" -o "%INST_BOOTSTRAP_FILE%"
if errorlevel 1 goto failed
:validate
powershell.exe -NoProfile -Command "$ErrorActionPreference='Stop'; $code=[IO.File]::ReadAllText($env:INST_BOOTSTRAP_FILE); if (-not $code.StartsWith('#')) { exit 1 }; $t=$null; $e=$null; [Management.Automation.Language.Parser]::ParseInput($code,[ref]$t,[ref]$e) | Out-Null; if ($e.Count) { exit 1 }"
if errorlevel 1 goto failed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INST_BOOTSTRAP_FILE%" %*
set "INST_RESULT=%errorlevel%"
del "%INST_BOOTSTRAP_FILE%"
exit /b %INST_RESULT%

:failed
del "%INST_BOOTSTRAP_FILE%" 2>nul
exit /b 1
