@echo off
rem Let's snag admin privs. Registry maniuplation might require big boy trousers, but since we can't escalate as a chad system user, we will have to make due with admin pullups.
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
cd /d "%~dp0"

cls

:: Windows 8.1 and below likely won't work with this tool, but I will update it if it turns out Windows 8 does work or something.
setlocal
for /f "tokens=4-5 delims=. " %%i in ('ver') do set VERSION=%%i.%%j
if not "%version%"=="10.0" (
 goto BadWindows
)

:: Sometimes we will be booted into a computer with multiple Windows installations. This should let us be choosy beggers.
echo The following drives appear to have a Windows install:
:: My specific live Windows doesn't work with a specific WMIC command that facilitates this need for some reason. No one else on the planet is having the issue, so it could be user error. This also means we need to use Diskpart, which isn't optimal, but it is what it is.
:: Let's write a script file for Diskpart.
echo list volume > "%TEMP%\Diskpart.srp"
echo exit >> "%TEMP%\Diskpart.srp"
:: We need to execute Diskpart to output a file containing drives and their letters.
:: My initial plan was to output the disk list to temp as well, but a for loop won't load from a temp folder if it has a space in the path. Because why not?
diskpart /s "%TEMP%\Diskpart.srp" > Disk.srp
:: We are going to loop the output and check each mounted drive.
setlocal enableextensions enabledelayedexpansion

::We want to set some kind of var that we can use to count.
set Count=1
::Let's read this back and print each line.
for /F "usebackq tokens=*" %%A in ("Disk.srp") do (
if /i !Count! gtr 5 set Text=%%A
if /i !Count! gtr 5 if "!Text!"=="Leaving DiskPart..." goto Continue
if /i !Count! gtr 5 if not "!Text:~13,1!" == " " set Drive=!Text:~13,1!:\windows
if /i !Count! gtr 5 if not "!Text:~13,1!" == " " if exist !Drive! echo !Drive!
set /A Count += 1
)
endlocal

:Continue
set /p Drive="Enter the drive letter of Windows. If no drive letter supplied, assuming C. --> "
if "%Drive%"=="" set Drive=C
set /u Drive=%Drive:~,1%
if /I "%Drive%"=="x" goto LiveWindows
if not exist %Drive%:\Windows goto NoWindows
if /I "%Drive%:"=="%SYSTEMDRIVE%" (set Live=No) else (set Live=Yes)

::We don't need the drive letter to look elegant, but we also don't need a mini fridge at the computer desk when it's just 25 steps from the kitchen, Karen!
::This will convert the user's more-than-likely lower case letter to an uppercase letter. Don't test me, or we will go with uppestcase letters and break reality.
setlocal EnableDelayedExpansion
set "alphabet=abcdefghijklmnopqrstuvwxyz"
set "alphabet_upper=ABCDEFGHIJKLMNOPQRSTUVWXYZ"
for /l %%i in (0,1,25) do (
  set "letter=!alphabet:~%%i,1!"
  set "letter_upper=!alphabet_upper:~%%i,1!"
  if /i "%Drive%"=="!letter!" set "Drive=!letter_upper!"
)
endlocal & set "Drive=%Drive%"



:: If we are on Live Windows, then mount the registry. This will throw an error message if this is ran a second time on the same instance of Live Windows. If it worked the first time, ignore the error message the second time.
if "%Live%"=="Yes" (
 reg load HKLM\temphive %DRIVE%:\Windows\System32\config\SOFTWARE > nul
 if "%ERRORLEVEL%"=="0" (
  echo Registry seems to be loaded correctly.
 )
 if "%ERRORLEVEL%"=="1" (
  echo Registry did not load correctly.
 )
)

:: Now we can do some registry sniffing for stuff.
if "%Live%"=="Yes" set RegLoc="HKLM\temphive\Microsoft\Windows NT\CurrentVersion"
if "%Live%"=="No" set RegLoc="HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion"

FOR /F "tokens=2* skip=2" %%a in ('reg query %RegLoc% /v "EditionID"') do SET Temp=%%b
set Edition=%Temp%
FOR /F "tokens=2* skip=2" %%a in ('reg query %RegLoc% /v "CurrentBuildNumber"') do SET Temp=%%b
set Build=%Temp%
FOR /F "tokens=2* skip=2" %%a in ('reg query %RegLoc% /v "UBR"') do SET Temp=%%b
set /a Rev=%Temp%
FOR /F "tokens=2* skip=2" %%a in ('reg query %RegLoc% /v "ProductName"') do SET Temp=%%b
set /a WindowsVersion=%Temp:~8,2%
reg query %RegLoc% /v BuildLabEx | findstr amd64
if "%ERRORLEVEL%" == "0" set WordSize=64
if "%ERRORLEVEL%" == "1" set WordSize=32

:: Now that we have all the data we need, we should unload the registry.
if "%Live%"=="Yes" reg unload HKLM\temphive > nul


:: We are going to use a table to convert the build ID into a version, and it lets us easily goto a location.
:: I know the string exists in registry as of 2009, but I don't know if it works on previous versions, so this is a failsafe.

if "%Build%"=="10240" set Version=1507
if "%Build%"=="14393" set Version=1607
if "%Build%"=="15063" set Version=1703
if "%Build%"=="16299" set Version=1709
if "%Build%"=="17134" set Version=1803
if "%Build%"=="17763" set Version=1809
if "%Build%"=="18362" set Version=1903
if "%Build%"=="18363" set Version=1909
if "%Build%"=="19041" set Version=2004
if "%Build%"=="19042" set Version=20H2
if "%Build%"=="19043" set Version=21H1
if "%Build%"=="19044" set Version=21H2
if "%Build%"=="22000" set Version=21H2
if "%Build%"=="22621" set Version=22H2


echo Script Details:
echo Batch Locale:		%~dp0
echo Selected Drive Letter:	%Drive%:
echo Booted Drive Letter:	%SYSTEMDRIVE%
echo Is live Windows:	%Live%
if %WindowsVersion%=="11" (
echo ---Windows 11 Details---
) else (
echo ---Windows 10 Details---
)
echo Edition:		%Edition%
echo Type:			%WordSize%-bit
echo Version:		%Version%
echo Build:			%Build%
echo Revision:		%Rev%

pause

::Apparently, DISM does not need an Index value or a file identifier to run.
::We are going to try not using those and see how it works. We might be able to skip a ton of goto and labels and other nonsense.
::Depending on the media, we may have to do a ESD vs WIM vs SWM command line, though,so let's not get too comfortable.


if not exist "%Build%\%WordSize%\install.*" (
echo This build of Windows has not been added to the AutoDISM kit.
echo Please find an AIO install file for build %Build% running %WordSize%-bit.
echo Windows %WindowsVersion% - %Build% Type - %WordSize% Edition - %Edition% >> NoOS.log

goto end
)


mkdir %Drive%:\DISMScratchDir > nul
if "%Live%"=="Yes" set Image=^/Image:%Drive%:
if "%Live%"=="No" set Image=^/Online

:: If pending.xml or migration.xml exists, dism will fail. We'll need to handle them.
:: Because Windows is stupid, the files that prevent repair might be locked, requiring a repair to fix.
:: Ignore the error messages for now.
:: Some Windows versions are glitched out where the pending file is deleted, but Windows still thinks something is pending. We will run this first, then delete the pending files if they exist.
dism %Image%  /ScratchDir=%Drive%:\DISMScratchDir /Cleanup-Image /RevertPendingActions
attrib -s -h -r %Drive%:\windows\winsxs\pending.xml
attrib -s -h -r %Drive%:\windows\winsxs\migration.xml
del %Drive%:\windows\winsxs\pending.xml
del %Drive%:\windows\winsxs\migration.xml


dism %Image% /Cleanup-Image /StartComponentCleanup /ScratchDir=%Drive%:\DISMScratchDir

if exist "%Build%\%WordSize%\install.wim" (
dism %Image% /Cleanup-Image /RestoreHealth /Source:%Build%\%WordSize%\install.wim /LimitAccess /ScratchDir=%Drive%:\DISMScratchDir
)
if exist "%Build%\%WordSize%\install.esd" (
dism %Image% /Cleanup-Image /RestoreHealth /Source:%Build%\%WordSize%\install.esd /LimitAccess /ScratchDir=%Drive%:\DISMScratchDir
)
if exist "%Build%\%WordSize%\install.swm" (
dism %Image% /Cleanup-Image /RestoreHealth /Source:%Build%\%WordSize%\install.swm /LimitAccess /ScratchDir=%Drive%:\DISMScratchDir
)
rmdir /s /q %Drive%:\DISMScratchDir

:sfc

:: Once DISM is done, we can SFC.
if "%Live%"=="Yes" sfc /scannow /offbootdir=%Drive%: /offwindir=%Drive%:\windows
if "%Live%"=="No" sfc /scannow
pause

goto end

:BadWindows
echo This batch file will only run on Windows 10 and 11.
echo Doing otherwise will probably break something.
goto end

:NoWindows
echo I can't find a Windows directory here.
echo Check your drive? If it IS correct, please report this incident.
goto end

:LiveWindows
cls
echo X drive is usually Live Windows or Recovery Environment.
CHOICE /C YN /M "Do you want to proceed with drive letter X as your Windows drive"
IF "%ERRORLEVEL%"=="1" goto Continue
IF "%ERRORLEVEL%"=="2" goto end


:end
del disk.srp
del "%TEMP%\diskpart.srp"
pause
