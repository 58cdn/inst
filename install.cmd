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
powershell.exe -NoProfile -Command "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol=[Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; if (-not $env:INST_BOOTSTRAP_BASE.StartsWith('https://')) { throw 'INST_RAW_BASE_URL must use HTTPS' }; Invoke-WebRequest -UseBasicParsing -Uri ($env:INST_BOOTSTRAP_BASE + '/install.ps1') -OutFile $env:INST_BOOTSTRAP_FILE"
if errorlevel 1 exit /b 1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%INST_BOOTSTRAP_FILE%" %*
set "INST_RESULT=%errorlevel%"
del "%INST_BOOTSTRAP_FILE%"
exit /b %INST_RESULT%
