@echo off
setlocal
where pwsh.exe >nul 2>nul
if errorlevel 1 goto legacy
pwsh.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0winmanage.ps1" %*
exit /b %errorlevel%
:legacy
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0winmanage.ps1" %*
exit /b %errorlevel%
