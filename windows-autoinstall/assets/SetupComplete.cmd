@echo off
setlocal

set "AI_NODE_ROOT=C:\ProgramData\__APP_PREFIX_CMD__"
if not exist "%AI_NODE_ROOT%\provision.ps1" (
  >"%WINDIR%\Temp\ai-node-setup-error.txt" echo Missing %AI_NODE_ROOT%\provision.ps1
  exit /b 1
)

icacls.exe "%AI_NODE_ROOT%" /inheritance:r /grant:r "SYSTEM:(OI)(CI)F" "Administrators:(OI)(CI)F"
if errorlevel 1 exit /b 1

schtasks.exe /Create /TN "__APP_PREFIX_CMD__-Provision" /SC MINUTE /MO 5 /RU SYSTEM /RL HIGHEST /TR "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File C:\ProgramData\__APP_PREFIX_CMD__\provision.ps1" /F
if errorlevel 1 exit /b 1

schtasks.exe /Run /TN "__APP_PREFIX_CMD__-Provision"
if errorlevel 1 exit /b 1

exit /b 0
