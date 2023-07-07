@echo off

:: We need admin permissions for DISM to do its job, and for reg to mount and unmount a registry hive.
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
:SkipAdmin

CLS

:: Check if the Windows we are on is capable of performing the repair. Windows 7 and older is not able to perform this type of Windows repair with the DISM tool.
:: I attempted to add Windows 8 into the DISM kit, but it started to turn into a mess, so I opted to remove its support until I have more patience to deal with it.

setlocal
for /f "tokens=4-5 delims=. " %%i in ('ver') do set WinVer=%%i.%%j
if not "%WinVer%"=="10.0" goto BadWindows

:: Check for any Windows directories on any storage devices that aren't CD drives.
:: For notations sake, some Live Windows doesn't like WMIC and some installations run diskpart in a different window, so this is a third way to perform this check.
echo The following drives appear to have a Windows install:
setlocal enabledelayedexpansion
for %%a in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
  fsutil fsinfo drivetype %%a: | find /i "Fixed" >nul
  if not errorlevel 1 (
    if exist %%a:\windows echo %%a:
  ) else (
    fsutil fsinfo drivetype %%a: | find /i "Removable" >nul
    if not errorlevel 1 (
      if exist %%a:\windows echo %%a:\windows
    )
  )
)
endlocal

set Drive=
set /p Drive="Enter the drive letter of Windows. If no drive letter supplied, assuming C. --> "
if "%Drive%"=="" set Drive=C
set Drive=%Drive:~,1%
if not exist %Drive%:\Windows goto NoWindows

::This will convert the user's more-than-likely lower case letter to an uppercase letter.
::It just makes the echo cleaner since it matches command prompts display, and plays nicer with "quoted" string for exact comparisons later on if we need them.
setlocal EnableDelayedExpansion
set "alphabet=abcdefghijklmnopqrstuvwxyz"
set "alphabet_upper=ABCDEFGHIJKLMNOPQRSTUVWXYZ"
for /l %%i in (0,1,25) do (
  set "letter=!alphabet:~%%i,1!"
  set "letter_upper=!alphabet_upper:~%%i,1!"
  if /i "%Drive%"=="!letter!" set "Drive=!letter_upper!"
)
endlocal & set "Drive=%Drive%"

:: Knowing if Windows is online or offline helps us when we mount the registry, and specify the location of the registry keys.
:: We also use this later in different part of DISM handlimg.
if "%Drive%:"=="%SYSTEMDRIVE%" (set Status=Online) else (set Status=Offline)

:: We can mount the registry now, if we are working on an offline Windows.
if "%Status%"=="Offline" (
 reg load HKLM\temphive %DRIVE%:\Windows\System32\config\SOFTWARE> nul 2>&1
 set RegLoc="HKLM\temphive\Microsoft\Windows NT\CurrentVersion"
 if "%ERRORLEVEL%"=="0" (
  echo Registry seems to be loaded correctly.
 )
 if "%ERRORLEVEL%"=="1" (
  goto PossibleCorrpuptWindows
 )
) else (
set RegLoc="HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
)

:: If all has gone well, let's pull the version of Windows and make sure we are working on one we can actually work with.
:: Anything below Windows 10 is not supported.
FOR /F "tokens=4 skip=2" %%a in ('reg query %RegLoc% /v "ProductName"') DO SET WindowsVersion=%%a
IF NOT "%WindowsVersion%"=="10" IF NOT "%WindowsVersion%"=="11" goto BadWindows

FOR /F "tokens=2* skip=2" %%a in ('reg query %RegLoc% /v "EditionID"') do SET Temp=%%b
set Edition=%Temp%
FOR /F "tokens=2* skip=2" %%a in ('reg query %RegLoc% /v "CurrentBuildNumber"') do SET Temp=%%b
set Build=%Temp%
FOR /F "tokens=2* skip=2" %%a in ('reg query %RegLoc% /v "ProductName"') do SET Temp=%%b
set WindowsVersion=%Temp:~8,2%

:: Just wanted to add a quick note that I have no intention to add Itanium or ARM based support, since I can't test them.
:: If you are running this on one of those platforms, you have no one to blame but yourself.
:: Do a pull request, add the appropriate version to the kit, adjust the scrpt below, and if it works, let me know and I will merge the change.
reg query %RegLoc% /v BuildLabEx | findstr amd64 > nul 2>&1
if "%ERRORLEVEL%" == "0" set WordSize=64
if "%ERRORLEVEL%" == "1" set WordSize=32

:: Windows 64-bit cannot repair Windows 32-bit, and vice versa. We will terminate if this is the case.
IF "%PROCESSOR_ARCHITECTURE%"=="AMD64" (
if not "%WordSize%"=="64" goto BadWordSize
) ELSE IF "%PROCESSOR_ARCHITECTURE%"=="x86" (
if not "%WordSize%"=="32" goto BadWordSize
)

echo --- Script Details ---
echo Batch Locale:			%~dp0
echo Booted Drive Letter:		%SYSTEMDRIVE%
echo --- Selected Windows System Information ---
echo Selected Drive Letter:		%Drive%:
echo Selected Windows status:	%Status%
echo Registry Location:		%RegLoc%
echo --- Selected Windows Details ---
echo Windows version:		%WindowsVersion%
echo Windows Edition:		%Edition%
echo Windows Build:			%Build%
echo Windows Type:			%WordSize%-bit

if not exist "%Build%\%WordSize%\install.*" goto NoInstallFile

::We have three versions of the installer file, at least that I know of, that can be used with DISM. Here we will specify which, since it makes the batch scripting cleaner in the long run.
if exist "%Build%\%WordSize%\install.wim" (
set Ext=wim
)
if exist "%Build%\%WordSize%\install.esd" (
set Ext=esd
)
if exist "%Build%\%WordSize%\install.swm" (
set Ext=swm
)


:: At this point, we have to deal with unique version of Windows and their unique DISM displayed name.
:: If you find an edition of Windows that isn't covered here, do a pull request, adjust the script to work, and suggest a merge.

:: Some editions unbrella under other editions, and Windows 11 have different rules for these umbrellas, so while these seem to be correct, submit a ticket if something doesn't go as planned.

if "%WindowsVersion%"=="11" (
if "%Edition%"=="Core" set EditionC=Windows 11 Home
if "%Edition%"=="CoreN" set EditionC=Windows 11 Home N
if "%Edition%"=="Home" set EditionC=Windows 11 Home
if "%Edition%"=="HomeN" set EditionC=Windows 11 Home N
if "%Edition%"=="Professional" set EditionC=Windows 11 Pro
if "%Edition%"=="ProfessionalN" set EditionC=Windows 11 Pro N
if "%Edition%"=="EnterpriseS" set EditionC=Windows 11 Pro for Workstations
if "%Edition%"=="Enterprise" set EditionC=Windows 11 Pro for Workstations
if "%Edition%"=="EnterpriseN" set EditionC=Windows 11 Pro N for Workstations
if "%Edition%"=="Education" set EditionC=Windows 11 Pro Education
if "%Edition%"=="EducationN" set EditionC=Windows 11 Pro Education N
)

if "%WindowsVersion%"=="10" (
if "%Edition%"=="EnterpriseS" set EditionC=Windows 10 Enterprise
if "%Edition%"=="Enterprise" set EditionC=Windows 10 Enterprise
if "%Edition%"=="EnterpriseN" set EditionC=Windows 10 Enterprise N
if "%Edition%"=="Education" set EditionC=Windows 10 Education
if "%Edition%"=="EducationN" set EditionC=Windows 10 Education N
if "%Edition%"=="Professional" set EditionC=Windows 10 Pro
if "%Edition%"=="ProfessionalN" set EditionC=Windows 10 Pro N
if "%Edition%"=="Home" set EditionC=Windows 10 Home
if "%Edition%"=="HomeN" set EditionC=Windows 10 Home N
if "%Edition%"=="Core" set EditionC=Windows 10 Home
if "%Edition%"=="CoreN" set EditionC=Windows 10 Home N
if "%Edition%"=="CoreSingleLanguage" set EditionC=Windows 10 Home Single Language
)

:: If all this mess makes sense and works, the next thing to do is check the installer for a compatible repair index.
setlocal enabledelayedexpansion
for /f "tokens=*" %%A in ('Dism /Get-ImageInfo /ImageFile:%Build%\%WordSize%\install.%Ext% ^| findstr "Index"') do (
    REM Remove the first seven characters from each line
    set "line=%%A"
    echo !line:~8!>> index.tmp
)

for /f "delims=" %%A in ('type "%CD%\index.tmp"') do (
    for /f "tokens=2 delims=:" %%B in ('Dism /Get-ImageInfo /ImageFile:%Build%\%WordSize%\install.%Ext% /index:%%A ^| findstr "Name"') do (
    set "index=%%A"
    set "name=%%B"
	set name=!name:~1!
	if !EditionC!==!name! goto GoodInstaller
    )
)

:GoodInstaller

echo The index number we need is %index%.
echo The name of the index is %name%.
echo.
echo Let's do this!

if "%Status%"=="Offline" set Image=^/Image:%Drive%:
if "%Status%"=="Online" set Image=^/Online
mkdir %Drive%:\DISMScratchDir > nul

:DISMStart
:: Some might say this is a bad idea to do this, but this has cleared up a lot of issues, so edit it if you don't like it.
:: I think this only works in Live Windows. Will test when it becomes relevant.
dism %Image%  /ScratchDir=%Drive%:\DISMScratchDir /Cleanup-Image /RevertPendingActions
attrib -s -h -r %Drive%:\windows\winsxs\pending.xml> nul 2>&1
attrib -s -h -r %Drive%:\windows\winsxs\migration.xml> nul 2>&1
del %Drive%:\windows\winsxs\pending.xml> nul 2>&1
del %Drive%:\windows\winsxs\migration.xml> nul 2>&1

:: Running this process next seems to help make the repair more reliable. No real data to back it up, though.
dism %Image% /Cleanup-Image /StartComponentCleanup /ScratchDir=%Drive%:\DISMScratchDir

:: We are going to perform a repair that doesn't use Windows Update. Usually, this fixes it faster, and online may not be needed.
dism %Image% /Cleanup-Image /RestoreHealth /Source:%Build%\%WordSize%\install.%Ext% /LimitAccess /ScratchDir=%Drive%:\DISMScratchDir
if not "%ERRORLEVEL%"=="0" goto DISMError

:sfc

:: Once DISM is done, we can SFC.
if "%Status%"=="Offline" sfc /scannow /offbootdir=%Drive%: /offwindir=%Drive%:\windows
if "%Status%"=="Online" sfc /scannow

goto end

:BadWindows
echo This version of Windows is unsupported.
goto end

:NoWindows
echo Windows was not detected at the specified drive letter.
goto end

:BadWordSize
echo You cannot repair Windows with a mismatched processor architecture.
echo Please repair with a Windows install under %WordSize%-bit.
goto end

:NoInstallFile
echo This build of Windows has not been added to the AutoDISM kit.
echo As long as you have an install file for the edition of Windows you need to fix, it should just work.
echo Windows %WindowsVersion% - %Build% Type - %WordSize% Edition - %Edition% >> NoOS.log
goto end

:PossibleCorrpuptWindows
echo Registry mounting has failed. To prevent further damage, AutoDISM has terminated.
goto end

:DISMError
if "%Status%"=="Offline" (
echo DISM seems to have failed. If you can still boot this operating system, try running in Windows with internet.
echo DISM should try to fetch missing or broken files from Windows Update. Likely, an updated component mismatched in the install file and DISM prevented more damage by not reverting to a version that will cause more damage.
echo Due to some limitations in how DISM works, this doesn't appear to be something that can be done with an offline Windows system.
goto end
)
echo We are going to try again, only DISM will not be limited to the install file for its sources.
echo This might take more time, but it also just might fix the issues. Or make it worse. Who knows?
ping 8.8.8.8 -n 1 -w 1000 > nul
if "%ERRORLEVEL%"=="0" (
dism %Image% /Cleanup-Image /RestoreHealth /Source:%Build%\%WordSize%\install.%Ext% /ScratchDir=%Drive%:\DISMScratchDir
goto sfc
)
goto NoInternet

:NoInternet
echo Please connect internet to this computer, then just wait to move on with things.
echo If your internet is immovable object and you are unstoppable force, close window or CTRL + C to close by force.
ping 127.0.0.1 -n 8 > nul
goto DISMError

:end
if "%Status%"=="Offline" reg unload HKLM\temphive> nul 2>&1
rmdir /s /q %Drive%:\DISMScratchDir> nul 2>&1
del index.tmp> nul 2>&1
pause
