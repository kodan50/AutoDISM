@echo off
setlocal EnableExtensions DisableDelayedExpansion
title Update kit DISM

:: ===========================================================================
::  UpdateDISM - copies the Windows ADK's DISM into the AutoDISM kit:
::
::      .\DISM\AMD64\   .\DISM\X86\   .\DISM\ARM64\   (whichever the ADK has)
::
::  AutoDISM.bat uses that copy when the booted environment's own DISM is older
::  than the Windows install being repaired, e.g. a Windows 10 WinPE on a 24H2 PC.
::
::  Run it on a PC with the Windows ADK installed. Only the "Deployment Tools"
::  feature is needed. The DISM you get is the version of the ADK installed here;
::  to update, install a newer ADK and run this again. The previous copy is moved
::  to .\DISM\Archive\<ARCH>_<version>.
:: ===========================================================================

pushd "%~dp0"
set "Root=%~dp0"
set "KitDismRoot=%Root%DISM"

:: ---- Find the ADK ------------------------------------------------------------
set "KitsRoot="
for %%K in ("HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows Kits\Installed Roots" "HKLM\SOFTWARE\Microsoft\Windows Kits\Installed Roots") do (
  if not defined KitsRoot for /f "tokens=2,*" %%a in ('reg query %%K /v KitsRoot10 2^>nul ^| findstr /c:"REG_"') do set "KitsRoot=%%b"
)
if not defined KitsRoot set "KitsRoot=%ProgramFiles(x86)%\Windows Kits\10\"
if not "%KitsRoot:~-1%"=="\" set "KitsRoot=%KitsRoot%\"
set "DandIRoot=%KitsRoot%Assessment and Deployment Kit\Deployment Tools"

setlocal EnableDelayedExpansion
if not exist "!DandIRoot!\amd64\DISM\dism.exe" if not exist "!DandIRoot!\x86\DISM\dism.exe" if not exist "!DandIRoot!\arm64\DISM\dism.exe" goto :NoADK

echo Windows ADK Deployment Tools: !DandIRoot!
echo Kit DISM folder:              !KitDismRoot!
echo.

:: CopyDandI.cmd expects the Deployment and Imaging Tools environment.
if exist "!DandIRoot!\DandISetEnv.bat" call "!DandIRoot!\DandISetEnv.bat" >nul 2>&1

set "Copied=0"
set "Current=0"
set "Failed=0"
for %%A in (amd64 x86 arm64) do call :CopyArch %%A

echo.
echo Done. Updated: !Copied!   Already current: !Current!   Failed: !Failed!
if !Failed! GTR 0 echo Check the messages above for the architecture that failed.
goto :End

:NoADK
echo The Windows ADK Deployment Tools were not found on this PC.
echo Looked in: !DandIRoot!
echo.
echo Install the current Windows ADK from:
echo   https://learn.microsoft.com/windows-hardware/get-started/adk-install
echo Only the "Deployment Tools" feature is needed. Then run this script again.
goto :End

:End
echo.
pause
popd
endlocal
exit /b

:: ===========================================================================
::  :CopyArch <amd64|x86|arm64>  - copies one architecture's DISM into the kit
:: ===========================================================================
:CopyArch
set "AdkArch=%~1"
set "Src=!DandIRoot!\!AdkArch!\DISM"
if /i "!AdkArch!"=="amd64" set "KitArch=AMD64"
if /i "!AdkArch!"=="x86"   set "KitArch=X86"
if /i "!AdkArch!"=="arm64" set "KitArch=ARM64"
set "Dest=!KitDismRoot!\!KitArch!"

if not exist "!Src!\dism.exe" (
  echo !KitArch!: not included in this ADK, skipped.
  exit /b 0
)

:: Read the version from the file itself, so this works for every architecture.
set "AutoDISM_File=!Src!\dism.exe"
set "NewVer="
for /f "delims=" %%v in ('powershell -NoProfile -Command "(Get-Item -LiteralPath $env:AutoDISM_File).VersionInfo.ProductVersion"') do set "NewVer=%%v"
if not defined NewVer set "NewVer=unknown"

set "OldVer="
if exist "!Dest!\VERSION.txt" for /f "usebackq tokens=1,* delims==" %%a in ("!Dest!\VERSION.txt") do if /i "%%a"=="DISM" set "OldVer=%%b"

if exist "!Dest!\dism.exe" if /i "!OldVer!"=="!NewVer!" (
  echo !KitArch!: already has DISM !NewVer!.
  set /a "Current+=1"
  exit /b 0
)

:: Move the previous copy aside rather than deleting it.
if exist "!Dest!\" (
  if not defined OldVer set "OldVer=unknown"
  set "ArchDir=!KitDismRoot!\Archive\!KitArch!_!OldVer!"
  if exist "!ArchDir!\" rmdir /s /q "!ArchDir!" >nul 2>&1
  if not exist "!KitDismRoot!\Archive\" mkdir "!KitDismRoot!\Archive" >nul 2>&1
  move "!Dest!" "!ArchDir!" >nul 2>&1
  if exist "!Dest!\" (
    echo !KitArch!: could not move the old copy aside. Is a file in it open?
    set /a "Failed+=1"
    exit /b 0
  )
  echo !KitArch!: previous DISM !OldVer! moved to Archive\!KitArch!_!OldVer!
)

if not exist "!KitDismRoot!\" mkdir "!KitDismRoot!" >nul 2>&1
echo !KitArch!: copying DISM !NewVer!...
:: Microsoft's documented copy method. It runs in its own cmd so an "exit" inside
:: it cannot end this script.
if exist "!DandIRoot!\CopyDandI.cmd" cmd /c ""!DandIRoot!\CopyDandI.cmd" !AdkArch! "!Dest!"" >nul 2>&1
:: Fallback: the same folder copied directly.
if not exist "!Dest!\dism.exe" robocopy "!Src!" "!Dest!" /E /R:1 /W:1 /NFL /NDL /NJH /NJS /NP >nul

if not exist "!Dest!\dism.exe" (
  echo !KitArch!: copy failed.
  set /a "Failed+=1"
  exit /b 0
)
if not exist "!Dest!\wimmountadksetup*.exe" echo !KitArch!: note - no wimmountadksetup installer was copied; AutoDISM will rely on the built-in mount driver.

>"!Dest!\VERSION.txt" echo DISM=!NewVer!
>>"!Dest!\VERSION.txt" echo ADK=!DandIRoot!
>>"!Dest!\VERSION.txt" echo Copied=!date! !time!
echo !KitArch!: done.
set /a "Copied+=1"
exit /b 0
