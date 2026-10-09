@echo off
setlocal
where pwsh.exe >nul 2>&1
if not errorlevel 1 (
  set "CGPU_PS_EXE=pwsh.exe"
) else (
  set "CGPU_PS_EXE=powershell.exe"
)
"%CGPU_PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0cgpu.ps1" %*
exit /b %errorlevel%
