@echo off
setlocal EnableExtensions

set "MEDIA="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
  if exist "%%D:\AI_NODE_MEDIA" set "MEDIA=%%D:"
)

if not defined MEDIA (
  echo The marked __APP_PREFIX_CMD__ installer media was not found.
  goto :normal
)

reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f
if errorlevel 1 goto :normal
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f
if errorlevel 1 goto :normal
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassCPUCheck /t REG_DWORD /d 1 /f
if errorlevel 1 goto :normal
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f
if errorlevel 1 goto :normal
reg add "HKLM\SYSTEM\Setup\LabConfig" /v BypassStorageCheck /t REG_DWORD /d 1 /f
if errorlevel 1 goto :normal
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\OOBE" /v BypassNRO /t REG_DWORD /d 1 /f
if errorlevel 1 goto :normal

"%MEDIA%\ai-node\diskselector.exe" ^
  --exclude-volume "%MEDIA%" ^
  --preferred-min-bytes __PREFERRED_MIN_TARGET_DISK_BYTES_CMD__ ^
  --answer-template "%MEDIA%\ai-node\autounattend.xml.in" ^
  --answer-output "X:\ai-node-autounattend.xml" ^
  --wipe-plan-output "X:\ai-node-wipe-secondary.txt"
if errorlevel 1 goto :normal

if not exist "X:\ai-node-wipe-secondary.txt" goto :no_secondary_disks

diskpart.exe /s "X:\ai-node-wipe-secondary.txt"
if errorlevel 1 echo WARNING: one or more secondary internal disks could not be cleaned; continuing with the selected Windows target.

:no_secondary_disks
echo Automatic target selection completed.
echo Windows Setup will wipe and partition the selected internal disk.
exit /b 0

:normal
echo.
echo Automatic disk selection was unavailable.
echo Continuing with ordinary Windows Setup so a target can be selected normally.
exit /b 2
