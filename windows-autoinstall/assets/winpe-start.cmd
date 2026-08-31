@echo off
setlocal EnableExtensions

wpeinit

set "MEDIA="
for %%D in (C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
  if exist "%%D:\AI_NODE_MEDIA" set "MEDIA=%%D:"
)

if not defined MEDIA goto :normal

echo Preparing __APP_PREFIX_CMD__ unattended installation.
call "%SYSTEMROOT%\System32\ai-node-prepare.cmd"
set "PREP_RESULT=%ERRORLEVEL%"
if "%PREP_RESULT%"=="2" goto :normal
if not "%PREP_RESULT%"=="0" goto :normal

"%SYSTEMDRIVE%\setup.exe" /unattend:"X:\ai-node-autounattend.xml"
goto :finished

:normal
echo Starting ordinary Windows Setup without an answer file.
"%SYSTEMDRIVE%\setup.exe"

:finished
echo Windows Setup returned. Shutting down.
wpeutil shutdown

:halt
ping -n 60 127.0.0.1 >nul
goto :halt
