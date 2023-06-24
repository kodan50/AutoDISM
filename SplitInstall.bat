@echo off

rem Apparently, DISM is incapable of running without admin permissions. I'm not sure why escalated permissions is needed to split a file apart that isn't in a locked directory, but whatever.
:init
 setlocal DisableDelayedExpansion
 set cmdInvoke=1
 set winSysFolder=System32
 set "batchPath=%~0"
 for %%k in (%0) do set batchName=%%~nk
 set "vbsGetPrivileges=%temp%\OEgetPriv_%batchName%.vbs"
 setlocal EnableDelayedExpansion

:getPrivileges
  if '%1'=='ELEV' (echo ELEV & shift /1 & goto gotPrivileges)
  ECHO Set UAC = CreateObject^("Shell.Application"^) > "%vbsGetPrivileges%"
  ECHO args = "ELEV " >> "%vbsGetPrivileges%"
  ECHO For Each strArg in WScript.Arguments >> "%vbsGetPrivileges%"
  ECHO args = args ^& strArg ^& " "  >> "%vbsGetPrivileges%"
  ECHO Next >> "%vbsGetPrivileges%"

  if '%cmdInvoke%'=='1' goto InvokeCmd 

  ECHO UAC.ShellExecute "!batchPath!", args, "", "runas", 1 >> "%vbsGetPrivileges%"
  goto ExecElevation

:InvokeCmd
  ECHO args = "/c """ + "!batchPath!" + """ " + args >> "%vbsGetPrivileges%"
  ECHO UAC.ShellExecute "%SystemRoot%\%winSysFolder%\cmd.exe", args, "", "runas", 1 >> "%vbsGetPrivileges%"

:ExecElevation
 "%SystemRoot%\%winSysFolder%\WScript.exe" "%vbsGetPrivileges%" %*
 exit

:gotPrivileges
 setlocal & cd /d %~dp0
 if '%1'=='ELEV' (del "%vbsGetPrivileges%" 1>nul 2>nul  &  shift /1)

cls

::First, let's determine the type of operation we need to perform. If install.esd exists and neither install.wim nor install.swm are present, we'll convert to WIM and then split to SWM.
::If install.wim exists, and neither install.esd nor install.swm do, we'll split the file.
::If any other condition exists, display an error to prevent file overwriting and potential issues.

:: Step one: If ESD exists, we'll assume conversion to WIM, followed by splitting the WIM file.
if exist install.esd (
 if exist install.wim goto Error
 if exist install.swm goto Error
:: I thought a simple conversion could happen. Boy howdy was I wrong. So, we perform a check and output what indexes the ESD has, then import based on the number of indexes we find.
:: This should retain the index names and data, but gives us the WIM we desire.
setlocal enabledelayedexpansion
for /f "tokens=*" %%A in ('Dism /Get-ImageInfo /ImageFile:install.esd ^| findstr "Index"') do (
    REM Remove the first seven characters from each line
    set "line=%%A"
    echo !line:~8!>> index.tmp
)

for /f "delims=" %%A in ('type "%CD%\index.tmp"') do (
    dism /Export-Image /SourceImageFile:install.esd /SourceIndex:%%A /DestinationImageFile:install.wim /Compress:Max /CheckIntegrity
)
:: And now we convert to FAT32 friendly SWM files. See, everything went swimmingly!
Dism /Split-Image /ImageFile:install.wim /SWMFile:install.swm /FileSize:4096
 goto end
)
if exist install.wim (
 if exist install.esd goto Error
 if exist install.swm goto Error
 Dism /Split-Image /ImageFile:install.wim /SWMFile:install.swm /FileSize:4096
)
endlocal
goto end

:Error
echo Existing files that should not exist exists.
echo Please remove the existing files that should not exist.
goto end

:end
pause
