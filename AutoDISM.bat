@echo off
setlocal EnableExtensions DisableDelayedExpansion
title AutoDISM

:: ===========================================================================
::  AutoDISM - repairs a Windows 10/11 install (online or offline) with DISM + SFC
::
::  Source layout (relative to this script):
::    .\Source\<Build>\<Build>.<UBR>.<ARCH>.WIM | .ESD | .SWM
::    e.g.  .\Source\26100\26100.4349.AMD64.WIM
::    Split WIMs:  26100.4349.AMD64.SWM, 26100.4349.AMD642.SWM, 26100.4349.AMD643.SWM ...
::
::  ARCH is the PROCESSOR_ARCHITECTURE value: AMD64, X86 or ARM64.
::  Note: the script path must not contain "!" or "%" (delayed expansion is used).
::
::  Optional newer DISM: .\DISM\<ARCH>\dism.exe, copied from the Windows ADK by
::  UpdateDISM.bat. Used only when the booted environment's DISM is older than
::  the install being repaired.
::
::  Logs (in .\Logs, or %TEMP%\AutoDISM if the script folder is read-only):
::    AutoDISM_<PC>_<time>.log       run log: every decision, exit code, and at the
::                                   end the relevant DISM and CBS error lines.
::                                   This is the file to post when asking for help.
::    AutoDISM_<PC>_<time>_dism.log  full DISM log for the same run.
:: ===========================================================================
set "ScriptVer=2026-10-30"

:: ---- Elevation -------------------------------------------------------------
:: WinPE always runs as SYSTEM. Anywhere else, relaunch elevated if needed.
set "IsPE="
reg query "HKLM\SYSTEM\CurrentControlSet\Control\MiniNT" >nul 2>&1 && set "IsPE=1"
if defined IsPE goto :Elevated
fltmc >nul 2>&1 && goto :Elevated

echo Requesting administrator rights...
:: A mapped drive letter (Z:) does not exist in the elevated session, so relaunch
:: through the \\server\share path. pushd below maps a temporary letter for it.
set "AutoDISM_Self=%~f0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p=$env:AutoDISM_Self; if($p -match '^([A-Za-z]):'){ $d=Get-PSDrive -Name $Matches[1] -PSProvider FileSystem -ErrorAction SilentlyContinue; if($d -and $d.DisplayRoot -like '\\*'){ $p=$d.DisplayRoot.TrimEnd('\')+$p.Substring(2) } }; Start-Process -FilePath $p -Verb RunAs" >nul 2>&1
if errorlevel 1 (
  echo Could not elevate. Right-click the script and choose "Run as administrator".
  pause
)
exit /b

:Elevated
pushd "%~dp0"
set "Root=%~dp0"
set "SelfPath=%~f0"
setlocal EnableDelayedExpansion
cls

set "HiveLoaded="
set "ScratchDir="
set "LogFile="
set "RunLog="
set "CandFile="
set "Result="

:: ---- Logs ------------------------------------------------------------------
set "LogDir=!Root!Logs"
if not exist "!LogDir!\" mkdir "!LogDir!" >nul 2>&1
type nul >>"!LogDir!\.write_test" 2>nul && del /f /q "!LogDir!\.write_test" >nul 2>&1 || set "LogDir=%TEMP%\AutoDISM"
if not exist "!LogDir!\" mkdir "!LogDir!" >nul 2>&1

set "Stamp=%date%_%time%"
for %%c in ("/" ":" "." ",") do set "Stamp=!Stamp:%%~c=-!"
set "Stamp=!Stamp: =!"
set "RunLog=!LogDir!\AutoDISM_%COMPUTERNAME%_!Stamp!.log"
set "LogFile=!LogDir!\AutoDISM_%COMPUTERNAME%_!Stamp!_dism.log"
type nul > "!RunLog!"

call :Log "AutoDISM !ScriptVer! started"
call :Log "Script: !SelfPath!"
call :Log "Computer: %COMPUTERNAME%   User: %USERNAME%   WinPE: !IsPE!"
call :Log "DISM log for this run: !LogFile!"

:: ---- Host checks -----------------------------------------------------------
:: The running OS (or WinPE) must be NT 10.0 for DISM to service Windows 10/11.
set "HostArch=%PROCESSOR_ARCHITECTURE%"
if defined PROCESSOR_ARCHITEW6432 set "HostArch=%PROCESSOR_ARCHITEW6432%"
set "HostMajor="
set "HostBuild=0"
set "HostVer="
for /f "tokens=2 delims=[]" %%v in ('ver') do (
  set "HostVer=%%v"
  for /f "tokens=2,4 delims=. " %%a in ("%%v") do (
    set "HostMajor=%%a"
    set "HostBuild=%%b"
  )
)
call :Log "Host: !HostVer!   arch !HostArch!   SystemDrive %SystemDrive%"
if not "!HostMajor!"=="10" goto :BadHost

:: ---- Pick the target install -----------------------------------------------
echo Windows installations found:
for %%a in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
  if exist "%%a:\Windows\System32\config\SOFTWARE" (
    if /i "%%a:"=="%SystemDrive%" (
      if not defined IsPE (
        echo    %%a:  [running system]
        call :Log "Found Windows on %%a: (running system)"
      )
    ) else (
      echo    %%a:
      call :Log "Found Windows on %%a:"
    )
  )
)
echo.

set "Drive="
set /p "Drive=Enter the drive letter of the Windows install to repair [C]: "
if not defined Drive set "Drive=C"
set "Drive=!Drive:~0,1!"

:: Validate and upper-case the letter in one pass.
set "Valid="
for %%L in (A B C D E F G H I J K L M N O P Q R S T U V W X Y Z) do (
  if /i "!Drive!"=="%%L" (
    set "Drive=%%L"
    set "Valid=1"
  )
)
call :Log "Drive entered: !Drive!"
if not defined Valid goto :NoWindows
if defined IsPE if /i "!Drive!:"=="%SystemDrive%" goto :NoWindows
if not exist "!Drive!:\Windows\System32\config\SOFTWARE" goto :NoWindows

if /i "!Drive!:"=="%SystemDrive%" (set "Status=Online") else (set "Status=Offline")
call :Log "Target: !Drive!:   Status: !Status!"

:: ---- Read version info from the target's registry --------------------------
if "!Status!"=="Offline" (
  set "RegKey=HKLM\AutoDISM_SW\Microsoft\Windows NT\CurrentVersion"
  rem Clear a hive left mounted by an earlier, interrupted run.
  reg unload HKLM\AutoDISM_SW >nul 2>&1
  reg load HKLM\AutoDISM_SW "!Drive!:\Windows\System32\config\SOFTWARE" >nul 2>&1
  set "rc=!errorlevel!"
  call :Log "reg load of !Drive!:\Windows\System32\config\SOFTWARE returned !rc!"
  if not "!rc!"=="0" goto :RegLoadFailed
  set "HiveLoaded=1"
) else (
  set "RegKey=HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion"
)

call :RegRead EditionID          Edition
call :RegRead CurrentBuildNumber Build
call :RegRead UBR                UBR
call :RegRead DisplayVersion     DisplayVersion
call :RegRead ProductName        ProductName
call :RegRead InstallationType   InstallationType
call :RegRead BuildLabEx         BuildLab
if not defined BuildLab call :RegRead BuildLab BuildLab
call :Log "Registry !RegKey!"
call :Log "  EditionID=!Edition!  CurrentBuildNumber=!Build!  UBR=!UBR!  DisplayVersion=!DisplayVersion!"
call :Log "  ProductName=!ProductName!  InstallationType=!InstallationType!"
call :Log "  BuildLabEx=!BuildLab!"

:: DISM mounts the offline hives itself, so ours must be gone before it runs.
if defined HiveLoaded (
  reg unload HKLM\AutoDISM_SW >nul 2>&1
  if errorlevel 1 (
    call :Say "Warning: could not unload the offline registry hive. DISM may fail to load the image."
  ) else (
    set "HiveLoaded="
  )
)

if not defined Edition goto :RegReadFailed
if not defined Build   goto :RegReadFailed
if not defined UBR     goto :RegReadFailed
if not defined BuildLab goto :RegReadFailed

:: UBR is a REG_DWORD and comes back as hex (0x10dd), convert to decimal.
set /a "UBR=!UBR!"
set /a "BuildNum=!Build!"

:: ProductName still says "Windows 10" on Windows 11, so go by build number.
if !BuildNum! LSS 10240 goto :BadWindows
if !BuildNum! GEQ 22000 (set "WinVer=11") else (set "WinVer=10")

:: Architecture of the TARGET install, taken from BuildLabEx (e.g. 26100.1.amd64fre...).
set "TargetArch="
if /i not "!BuildLab:amd64=!"=="!BuildLab!" set "TargetArch=AMD64"
if /i not "!BuildLab:arm64=!"=="!BuildLab!" set "TargetArch=ARM64"
if /i not "!BuildLab:x86fre=!"=="!BuildLab!" set "TargetArch=X86"
if not defined TargetArch goto :UnknownArch

:: Servicing branch = the first number of BuildLabEx. Enablement-package releases
:: keep their base build here (19045 -> 19041, 22631 -> 22621, 26200 -> 26100),
:: and every build in a branch gets the same cumulative update and UBR.
set "BranchBuild="
for /f "tokens=1 delims=." %%b in ("!BuildLab!") do set "BranchBuild=%%b"
set /a "BranchNum=BranchBuild" 2>nul
if !BranchNum! LSS 10240 (
  set "BranchBuild=!Build!"
  set "BranchNum=!BuildNum!"
)

if "!TargetArch!"=="AMD64" set "DismArch=x64"
if "!TargetArch!"=="X86"   set "DismArch=x86"
if "!TargetArch!"=="ARM64" set "DismArch=arm64"

call :Log "Derived: Windows !WinVer!  build !Build!.!UBR!  branch !BranchBuild!  arch !TargetArch! / !DismArch!"

:: Keep the original rule: only repair a matching architecture.
if /i not "!HostArch!"=="!TargetArch!" goto :BadArch

echo.
echo --- Script ---
echo Script folder:          !Root!
echo Booted from:            %SystemDrive%  ^(build !HostBuild!, !HostArch!^)
if defined IsPE echo Environment:            WinPE / WinRE
echo Run log:                !RunLog!
echo --- Target ---
echo Drive:                  !Drive!:
echo Status:                 !Status!
echo Windows:                Windows !WinVer! !DisplayVersion!
echo Edition ID:             !Edition!
echo Build:                  !Build!.!UBR!
if not "!BranchBuild!"=="!Build!" echo Servicing branch:       !BranchBuild!
echo Architecture:           !TargetArch!
echo.

:: ---- Pick the DISM to use ------------------------------------------------------
:: The built-in DISM is used unless it is older than the target's servicing branch
:: (a 19041 DISM services a 19045 install just fine) and the kit carries a newer
:: one in DISM\<arch>, copied from the Windows ADK by UpdateDISM.bat. Microsoft
:: supports a Windows 10 WinPE servicing Windows 11 only with the Windows 11 DISM.
call :DismVersion
call :Log "Built-in DISM version !DismVer!"
if !DismBuild! LSS !BranchNum! if exist "!Root!DISM\!HostArch!\dism.exe" call :UseKitDism
if !DismBuild! LSS !BranchNum! (
  call :Say "Warning: DISM !DismVer! is older than the target, build !BranchNum!."
  call :Say "         Older DISM versions can fail to service newer images. Run UpdateDISM.bat"
  call :Say "         on a PC with the Windows ADK, or boot a WinPE/WinRE of build !BranchNum! or newer."
  echo.
)
:: The target's own servicing stack still runs under this environment's kernel,
:: which a newer DISM cannot change.
if !HostBuild! LSS !BranchNum! if "!Status!"=="Offline" (
  call :Log "Note: environment build !HostBuild! is older than the target branch !BranchNum!. Offline servicing loads the target's servicing stack, which may need a newer environment."
)

:: ---- Prepare scratch ----------------------------------------------------------
set "ScratchDir=!Drive!:\AutoDISM_Scratch"
set "MountDir=!ScratchDir!\Mount"
if not exist "!ScratchDir!\" mkdir "!ScratchDir!" >nul 2>&1
:: Detach a source left mounted by an earlier run that was interrupted.
call :UnmountSource
call :FreeSpace
call :Log "Scratch: !ScratchDir!   free on !Drive!: !FreeBytes! bytes"

if "!Status!"=="Offline" (set "ImageArg=/Image:!Drive!:\") else (set "ImageArg=/Online")
set "DismCommon=/English !ImageArg! /ScratchDir:"!ScratchDir!" /LogPath:"!LogFile!""

:: ---- Build the list of repair sources --------------------------------------
:: The repair runs in two passes.
::  Pass 1: one attempt with the closest image: the exact UBR if the kit has it,
::          else the nearest older, else the nearest newer. The install's own build
::          folder is tried before its servicing branch. Images that lack the
::          edition are skipped and do not count as the attempt.
::  Pass 2: if that fails, DISM's log names every component version it could not
::          find (e.g. ..._10.0.26100.1591_...). The component store can hold
::          several versions of one component, each from a different update, so
::          one image is often not enough. For each needed version the kit image
::          with that exact UBR, or else the nearest newer one, is mounted; the
::          mounts are checked for the needed WinSxS folders; and one more repair
::          runs with all of them as sources at once. Versions no kit image holds
::          are written to NoOS.log as the exact images to add.
::  Pass 3: offline only. If every damaged version still left is an old copy that
::          a newer installed version has replaced (kept only so updates can be
::          uninstalled), AutoDISM offers StartComponentCleanup /ResetBase, which
::          deletes all such copies, then checks the store again. It asks first and
::          defaults to No, because installed updates can no longer be uninstalled.
set "SearchBuilds=!Build!"
if not "!BranchBuild!"=="!Build!" set "SearchBuilds=!Build! !BranchBuild!"
set "CandFile=%TEMP%\AutoDISM_sources.txt"
type nul > "%TEMP%\AutoDISM_sources.txt"
for %%B in (!SearchBuilds!) do (
  for %%X in (WIM ESD SWM) do (
    for %%F in ("!Root!Source\%%B\%%B.*.!TargetArch!.%%X") do (
      for /f "tokens=2 delims=." %%u in ("%%~nF") do call :AddCandidate %%B %%u %%X
    )
  )
)
sort "%TEMP%\AutoDISM_sources.txt" /o "%TEMP%\AutoDISM_sources.txt"

set "Candidates=0"
for /f "usebackq" %%c in ("%TEMP%\AutoDISM_sources.txt") do set /a "Candidates+=1"
call :Log "Searched builds: !SearchBuilds!   candidate files: !Candidates!"
call :AppendFile "%TEMP%\AutoDISM_sources.txt" "Candidate sources: sortkey build UBR format side(0 exact,1 older,2 newer)"

if !Candidates! EQU 0 (
  call :Say "No repair source for !TargetArch! was found under build: !SearchBuilds!"
  call :LogMissing "no source file in kit"
  if "!Status!"=="Offline" goto :NoInstallFile
  call :Say "Windows Update will be the only repair source."
  echo.
)

:: ---- DISM passes ------------------------------------------------------------
:: Nothing is reverted or removed. Pending update packages are only listed in the
:: run log, because one holding an exclusive servicing session can block cleanup
:: and repair, and that is worth knowing when reading a failure.
dism !DismCommon! /Get-Packages /Format:Table >"%TEMP%\AutoDISM_packages.txt" 2>nul
findstr /i /l /c:"Pending" "%TEMP%\AutoDISM_packages.txt" >"%TEMP%\AutoDISM_pending.txt" 2>nul
set "PendingCount=0"
for /f "usebackq" %%p in ("%TEMP%\AutoDISM_pending.txt") do set /a "PendingCount+=1"
if !PendingCount! GTR 0 (
  call :Say "Note: !PendingCount! update package(s) on this install are pending. They are listed in the run log."
  call :AppendFile "%TEMP%\AutoDISM_pending.txt" "Packages in a pending state"
) else (
  call :Log "No update packages are in a pending state."
)
del /f /q "%TEMP%\AutoDISM_packages.txt" "%TEMP%\AutoDISM_pending.txt" >nul 2>&1
if "!Status!"=="Online" (
  set "RebootPending=no"
  reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending" >nul 2>&1 && set "RebootPending=yes"
  call :Log "Servicing reboot pending: !RebootPending!"
)

echo [1/3] Running component cleanup...
dism !DismCommon! /Cleanup-Image /StartComponentCleanup
call :LogRc "StartComponentCleanup"
if not "!rc!"=="0" echo    Component cleanup returned !RcHex!. Continuing with the repair.

set "Repaired="
set "Attempts=0"
set "FallbackSource="
if !Candidates! GTR 0 (
  echo [2/3] Pass 1: repairing from the closest kit image...
  for /f "usebackq tokens=2-5" %%a in ("%TEMP%\AutoDISM_sources.txt") do (
    if not defined Repaired if !Attempts! EQU 0 call :TryCandidate %%a %%b %%c %%d
  )
)
set "MissingList="
set "Targeted="
if not defined Repaired if !Attempts! GTR 0 call :TargetedRepair
if not defined Repaired if !Attempts! GTR 0 if "!Status!"=="Offline" call :ResetBasePass
if defined Repaired goto :Sfc

echo.
if !Candidates! GTR 0 if !Attempts! EQU 0 (
  call :Say "None of the source images contain edition !Edition! for !DismArch!."
  call :LogMissing "edition not in any kit source"
)
if !Attempts! GTR 0 (
  call :Say "No local source could complete the repair."
  if defined MissingList (
    call :Say "The kit has no image containing the component versions from:!MissingList!"
    call :LogMissing "kit lacks component versions from:!MissingList!"
  ) else if defined Targeted (
    call :LogMissing "targeted repair failed although the kit images held the needed versions"
  ) else (
    call :LogMissing "local sources failed, no component list to target"
  )
)
if "!Status!"=="Offline" (
  call :Say "Offline images cannot use Windows Update as a repair source."
  if defined MissingList (
    call :Say "Add images of those updates to the kit, e.g. Source\!BranchBuild!\!BranchBuild!.UBR.!TargetArch!.WIM,"
  ) else (
    call :Say "Add Source\!BranchBuild!\!BranchBuild!.!UBR!.!TargetArch!.WIM to the kit,"
  )
  call :Say "or if this Windows can still boot, run AutoDISM from inside it with internet access."
  set "Result=Failed: no local source could repair the offline image"
  goto :End
)

:OnlineRetry
echo.
echo [2/3] Repairing with Windows Update allowed as a repair source...
if defined FallbackSource (
  call :Log "RestoreHealth with Windows Update, source !FallbackSource!"
  dism !DismCommon! /Cleanup-Image /RestoreHealth /Source:"!FallbackSource!"
) else (
  call :Log "RestoreHealth with Windows Update only"
  dism !DismCommon! /Cleanup-Image /RestoreHealth
)
call :LogRc "RestoreHealth with Windows Update"
if "!rc!"=="0"    goto :Sfc
if "!rc!"=="3010" goto :Sfc
echo Still failed ^(!RcHex!^). Windows Update may be unreachable.
choice /c RQ /n /m "Check the internet connection, then press R to retry or Q to quit: "
if errorlevel 2 (
  set "Result=Failed: RestoreHealth with Windows Update returned !RcHex!"
  goto :End
)
call :Log "User chose to retry"
goto :OnlineRetry

:Sfc
echo.
echo [3/3] Running SFC...
if "!Status!"=="Offline" (
  sfc /scannow /offbootdir=!Drive!:\ /offwindir=!Drive!:\Windows
) else (
  sfc /scannow
)
call :LogRc "SFC"
echo.
echo Repair finished. Restart the computer to complete any pending repairs.
set "Result=Repaired"
goto :End

:: ---- Error exits --------------------------------------------------------------
:BadHost
call :Say "This script must run on Windows 10/11 or a matching WinPE/WinRE."
set "Result=Stopped: unsupported host"
goto :End

:NoWindows
call :Say "Windows was not detected at the specified drive letter."
set "Result=Stopped: no Windows at the chosen drive"
goto :End

:RegLoadFailed
call :Say "Could not load the registry of !Drive!:. It may be corrupt or in use."
call :Say "AutoDISM has stopped to avoid causing further damage."
set "Result=Stopped: registry hive would not load"
goto :End

:RegReadFailed
call :Say "Could not read the version information from the registry of !Drive!:."
set "Result=Stopped: registry values missing"
goto :End

:BadWindows
call :Say "This version of Windows is unsupported. Only Windows 10 and 11 can be repaired."
set "Result=Stopped: unsupported Windows build"
goto :End

:UnknownArch
call :Say "Could not determine the architecture of the target install from BuildLabEx: !BuildLab!"
set "Result=Stopped: unknown architecture"
goto :End

:BadArch
call :Say "The target install is !TargetArch! but this environment is !HostArch!."
call :Say "Repair it from a !TargetArch! Windows or WinPE."
set "Result=Stopped: architecture mismatch"
goto :End

:NoInstallFile
call :Say "This build of Windows has not been added to the AutoDISM kit."
call :Say "Add a source as: Source\!Build!\!Build!.!UBR!.!TargetArch!.WIM, or .ESD / .SWM"
if not "!BranchBuild!"=="!Build!" call :Say "          or as: Source\!BranchBuild!\!BranchBuild!.!UBR!.!TargetArch!.WIM"
set "Result=Stopped: no source in kit for an offline install"
goto :End

:End
if not defined Result set "Result=Stopped"
if defined HiveLoaded reg unload HKLM\AutoDISM_SW >nul 2>&1
if defined ScratchDir call :UnmountSource
call :AnyMounted
if defined ScratchDir if exist "!ScratchDir!\" (
  if defined StillMounted (
    call :Say "A source image is still mounted under !ScratchDir!. Run: dism /Cleanup-Mountpoints"
  ) else (
    rmdir /s /q "!ScratchDir!" >nul 2>&1
  )
)
if defined CandFile if exist "!CandFile!" del /f /q "!CandFile!" >nul 2>&1
if defined RunLog (
  call :Log "Result: !Result!"
  call :Diagnostics
)
if defined CorruptSummary (
  echo.
  echo !CorruptSummary!
  if defined MultiVersion echo !MultiVersionNote!
  if defined OldEnvNote echo !OldEnvNote!
)
echo.
echo Result: !Result!
if defined RunLog (
  echo Run log: !RunLog!
  if /i not "!Result!"=="Repaired" echo If you need help with this failure, post the run log. It includes the DISM and CBS error lines.
)
echo.
pause
popd
endlocal
exit /b

:: ===========================================================================
::  Subroutines
:: ===========================================================================

:: :Log "<text>"  - appends a timestamped line to the run log
:Log
if not defined RunLog exit /b 0
set "LogMsg=%~1"
>>"!RunLog!" echo([!date! !time!] !LogMsg!
exit /b 0

:: :Say "<text>"  - shows a line on screen and logs it
:Say
set "LogMsg=%~1"
echo(!LogMsg!
if not defined RunLog exit /b 0
>>"!RunLog!" echo([!date! !time!] !LogMsg!
exit /b 0

:: :LogRc "<step>"  - records the exit code of the command that just ran.
:: Sets rc (decimal) and RcHex (e.g. 0x800F081F, the form Microsoft documents).
:LogRc
set "rc=%errorlevel%"
cmd /c exit %rc%
set "RcHex=0x%=ExitCode%"
call :Log "%~1 exit code !rc! (!RcHex!)"
exit /b 0

:: :AppendFile "<file>" "<title>"  - copies a whole file into the run log
:AppendFile
if not defined RunLog exit /b 0
>>"!RunLog!" echo(----- %~2 -----
if exist "%~1" type "%~1" >>"!RunLog!"
>>"!RunLog!" echo(----- end -----
exit /b 0

:: :AppendTail "<file>" <maxLines> "<title>"  - copies the last N lines of a file
:AppendTail
if not defined RunLog exit /b 0
set "TailCount=0"
if exist "%~1" for /f %%n in ('type "%~1" ^| find /c /v ""') do set "TailCount=%%n"
set /a "TailSkip=TailCount-%~2"
if !TailSkip! LSS 0 set "TailSkip=0"
>>"!RunLog!" echo(
>>"!RunLog!" echo(===== %~3: !TailCount! matching lines, last %~2 shown =====
if !TailCount! EQU 0 (
  >>"!RunLog!" echo(   [none]
  exit /b 0
)
if !TailSkip! GTR 0 (
  more +!TailSkip! "%~1" >>"!RunLog!"
) else (
  type "%~1" >>"!RunLog!"
)
exit /b 0

:: :FreeSpace  - sets FreeBytes for the target drive
:FreeSpace
set "FreeBytes=unknown"
for /f "tokens=3" %%s in ('dir /-c "!Drive!:\" 2^>nul ^| findstr /c:"bytes free"') do set "FreeBytes=%%s"
exit /b 0

:: :Diagnostics  - pulls the useful error lines out of the DISM and CBS logs.
:: SFC and online repairs write to the running system's CBS.log; offline DISM
:: servicing writes its CBS activity into this run's DISM log.
:Diagnostics
call :FreeSpace
call :Log "Free space on !Drive!: at end: !FreeBytes! bytes"
if not exist "!LogFile!" (
  call :Log "DISM did not run, so there are no DISM or CBS lines to include."
  exit /b 0
)
set "Excerpt=%TEMP%\AutoDISM_excerpt.txt"
findstr /i /l /c:", Error" /c:"CBS_E_" /c:"0x800f" /c:"Corrupt" /c:"Missing replacement" /c:"Repair failed" /c:"(p)" "!LogFile!" >"!Excerpt!" 2>nul
call :ScanSource
call :LastScan "!ScanSrc!" "%TEMP%\AutoDISM_corrupt.txt"
call :CorruptionSummary "%TEMP%\AutoDISM_corrupt.txt"
call :AppendTail "!Excerpt!" 150 "DISM log error lines"
set "CbsCopy=%TEMP%\AutoDISM_cbs.log"
copy /y "%SystemRoot%\Logs\CBS\CBS.log" "!CbsCopy!" >nul 2>&1
if exist "!CbsCopy!" (
  findstr /i /l /c:"(p)" /c:"Corrupt" /c:"Missing replacement" /c:"Cannot repair" /c:"[SR] Repairing" /c:"CBS_E_" /c:", Error" /c:"Total Detected" /c:"Summary:" "!CbsCopy!" >"!Excerpt!" 2>nul
  call :AppendTail "!Excerpt!" 200 "CBS log %SystemRoot%\Logs\CBS\CBS.log, error and repair lines"
  del /f /q "!CbsCopy!" >nul 2>&1
) else (
  call :Log "No CBS.log on this system. Offline repairs record their CBS activity in the DISM log above."
)
if exist "!Excerpt!" del /f /q "!Excerpt!" >nul 2>&1
exit /b 0

:: :RegRead <ValueName> <OutVar>  - reads a value from %RegKey%
:RegRead
set "%~2="
for /f "tokens=2,*" %%a in ('reg query "%RegKey%" /v "%~1" 2^>nul ^| findstr /c:"REG_"') do set "%~2=%%b"
exit /b 0

:: :CheckIndex <Index>  - sets MatchIndex/MatchName if the edition and arch match
:CheckIndex
set "IdxName="
set "IdxEdition="
set "IdxArch="
for /f "tokens=1,* delims=:" %%a in ('dism /English /Get-ImageInfo /ImageFile:"%SrcFile%" /Index:%~1 ^| findstr /b /c:"Name :" /c:"Edition :" /c:"Architecture :"') do (
  set "Key=%%a"
  set "Val=%%b"
  set "Val=!Val:~1!"
  if "!Key!"=="Name "         set "IdxName=!Val!"
  if "!Key!"=="Edition "      set "IdxEdition=!Val!"
  if "!Key!"=="Architecture " set "IdxArch=!Val!"
)
call :Log "  index %~1: !IdxName! [!IdxEdition!, !IdxArch!]"
if /i "!IdxEdition!"=="!Edition!" if /i "!IdxArch!"=="!DismArch!" (
  set "MatchIndex=%~1"
  set "MatchName=!IdxName!"
)
exit /b 0

:: :LogMissing "<Reason>"  - records an install the kit could not repair locally
:LogMissing
>>"!Root!NoOS.log" echo [%date% %time%] Windows !WinVer! !Edition! !Build!.!UBR! branch !BranchBuild! !TargetArch! - %~1
call :Log "Added to NoOS.log: %~1"
exit /b 0

:: :AddCandidate <Build> <UBR> <Ext>  - adds one source file to the try list.
:: Sort key: side (0 exact, 1 older, 2 newer), UBR distance, own build first, WIM/ESD/SWM.
:AddCandidate
set "CU="
set /a "CU=%~2" 2>nul
if not "!CU!"=="%~2" exit /b 0
if !CU! EQU !UBR! (
  set "Side=0"
  set "Dist=0"
) else if !CU! LSS !UBR! (
  set "Side=1"
  set /a "Dist=UBR-CU"
) else (
  set "Side=2"
  set /a "Dist=CU-UBR"
)
set "Pad=000000!Dist!"
set "Pad=!Pad:~-6!"
if "%~1"=="!Build!" (set "Pref=1") else (set "Pref=2")
set "ExtOrd=3"
if /i "%~3"=="WIM" set "ExtOrd=1"
if /i "%~3"=="ESD" set "ExtOrd=2"
>>"!CandFile!" echo !Side!!Pad!!Pref!!ExtOrd! %~1 %~2 %~3 !Side!
exit /b 0

:: :TryCandidate <Build> <UBR> <Ext> <Side>  - one local-only RestoreHealth attempt
:TryCandidate
:: Only the nearest usable source on each side, per build folder, is worth running.
if defined Tried_%~4_%~1 (
  call :Log "Skipping %~1.%~2.%~3: a nearer source on the same side was already tried"
  exit /b 0
)
set "SrcBuild=%~1"
set "SrcUBR=%~2"
set "Ext=%~3"
set "SrcDir=!Root!Source\!SrcBuild!"
set "SrcBase=!SrcBuild!.!SrcUBR!.!TargetArch!"
set "SrcFile=!SrcDir!\!SrcBase!.!Ext!"
echo.
echo Source: !SrcBase!.!Ext!
call :Log "Candidate !SrcFile!"
call :FindIndex
if not defined MatchIndex (
  call :Say "   Edition !Edition! is not in this image. Skipping."
  exit /b 0
)
call :Say "   Using index !MatchIndex!: !MatchName!"

:: Split images always need joining. Offline repairs also need a mountable WIM:
:: the target's servicing stack refuses wim:/esd: file sources offline
:: (CBS_E_NOT_ALLOWED_OFFLINE), so the index is mounted read-only and its
:: Windows folder is passed as the source instead. ESDs cannot be mounted.
set "ImageToUse=!SrcFile!"
set "IndexToUse=!MatchIndex!"
set "NeedExport="
if /i "!Ext!"=="SWM" set "NeedExport=1"
if "!Status!"=="Offline" if /i "!Ext!"=="ESD" set "NeedExport=1"
call :UnmountSource
if defined NeedExport (
  echo    Exporting index !MatchIndex! to a temporary WIM on !Drive!:...
  if exist "!ScratchDir!\source.wim" del /f /q "!ScratchDir!\source.wim" >nul 2>&1
  if /i "!Ext!"=="SWM" (
    dism /English /Export-Image /SourceImageFile:"!SrcFile!" /SWMFile:"!SrcDir!\!SrcBase!*.SWM" /SourceIndex:!MatchIndex! /DestinationImageFile:"!ScratchDir!\source.wim" /Compress:fast
  ) else (
    dism /English /Export-Image /SourceImageFile:"!SrcFile!" /SourceIndex:!MatchIndex! /DestinationImageFile:"!ScratchDir!\source.wim" /Compress:fast
  )
  call :LogRc "Export-Image to temporary WIM"
  if not "!rc!"=="0" (
    call :FreeSpace
    call :Say "   Export failed. Check free space on !Drive!:, now !FreeBytes! bytes, and that all .SWM parts are present."
    exit /b 0
  )
  set "ImageToUse=!ScratchDir!\source.wim"
  set "IndexToUse=1"
)

if "!Status!"=="Offline" (
  echo    Mounting the source read-only...
  mkdir "!MountDir!" >nul 2>&1
  dism /English /Mount-Image /ImageFile:"!ImageToUse!" /Index:!IndexToUse! /MountDir:"!MountDir!" /ReadOnly
  call :LogRc "Mount-Image read-only"
  if not "!rc!"=="0" (
    call :Say "   Could not mount this source image. Skipping it."
    call :UnmountSource
    exit /b 0
  )
  set "DismSource=!MountDir!\Windows"
) else if /i "!Ext!"=="ESD" (
  set "DismSource=esd:!ImageToUse!:!IndexToUse!"
) else (
  set "DismSource=wim:!ImageToUse!:!IndexToUse!"
)

set "Tried_%~4_%~1=1"
set /a "Attempts+=1"
set "Pass1Key=!SrcBuild!.!SrcUBR!.!Ext!"
if "!Status!"=="Online" if not defined FallbackSource if /i not "!Ext!"=="SWM" set "FallbackSource=!DismSource!"
if not "!SrcBuild!"=="!Build!" call :Say "   Branch source: the enablement package's own components cannot be repaired from it."
call :Log "RestoreHealth /LimitAccess with source !DismSource!"
dism !DismCommon! /Cleanup-Image /RestoreHealth /Source:"!DismSource!" /LimitAccess
call :LogRc "RestoreHealth /LimitAccess"
set "RestoreRc=!rc!"
set "RestoreHex=!RcHex!"
if "!Status!"=="Offline" call :UnmountSource
set "rc=!RestoreRc!"
set "RcHex=!RestoreHex!"
if "!rc!"=="0"    set "Repaired=1"
if "!rc!"=="3010" set "Repaired=1"
if not defined Repaired echo    This source could not complete the repair ^(!RcHex!^).
exit /b 0

:: :FindIndex  - finds the index in %SrcFile% matching the install's edition and arch.
:: Matches on the EditionID DISM reports, so no edition-name table is needed.
:FindIndex
set "MatchIndex="
set "MatchName="
set "IdxCount=0"
for /f "tokens=2 delims=: " %%i in ('dism /English /Get-ImageInfo /ImageFile:"%SrcFile%" 2^>nul ^| findstr /b /c:"Index :"') do (
  set /a "IdxCount+=1"
  if not defined MatchIndex call :CheckIndex %%i
)
if !IdxCount! EQU 0 call :Log "  DISM could not read any index from this file"
exit /b 0

:: :UnmountSource  - detaches every read-only source mount under the scratch folder
:UnmountSource
if not defined ScratchDir exit /b 0
if not exist "%ScratchDir%\" exit /b 0
for /d %%M in ("%ScratchDir%\Mount*") do (
  if exist "%%M\Windows\" (
    dism /English /Unmount-Image /MountDir:"%%M" /Discard >nul 2>&1
    call :LogRc "Unmount-Image /Discard %%~nxM"
  )
  if exist "%%M\Windows\" (
    dism /English /Cleanup-Mountpoints >nul 2>&1
    call :Log "Ran Cleanup-Mountpoints for %%~nxM, which would not detach"
  )
)
exit /b 0

:: :AnyMounted  - sets StillMounted if a source mount is still attached
:AnyMounted
set "StillMounted="
if not defined ScratchDir exit /b 0
if not exist "%ScratchDir%\" exit /b 0
for /d %%M in ("%ScratchDir%\Mount*") do if exist "%%M\Windows\" set "StillMounted=1"
exit /b 0

:: :CorruptionSummary "<file>"  - reads "(p) CSI Payload Corrupt" lines and records
:: how many files and which component versions are involved. When the same
:: component is corrupt in more than one version, each version needs an image
:: from the update that shipped it.
:CorruptionSummary
set "CorruptCount=0"
set "CorruptVers="
set "MultiVersion="
set "MultiComponents="
for /f "usebackq tokens=4 delims=	" %%c in (`findstr /l /c:"(p)	CSI Payload Corrupt" "%~1"`) do (
  set /a "CorruptCount+=1"
  for /f "tokens=2,4 delims=_" %%n in ("%%c") do (
    if not defined CP_%%n_%%o (
      set "CP_%%n_%%o=1"
      if not defined CV_%%o (
        set "CV_%%o=1"
        set "CorruptVers=!CorruptVers! %%o"
      )
      if defined CN_%%n if not defined CM_%%n (
        set "CM_%%n=1"
        set "MultiVersion=1"
        set "MultiComponents=!MultiComponents! %%n"
      )
      set "CN_%%n=1"
    )
  )
)
if !CorruptCount! EQU 0 exit /b 0
set "CorruptSummary=Corrupt payload files: !CorruptCount!. Component versions involved:!CorruptVers!"
call :Log "!CorruptSummary!"
if defined MultiVersion (
  set "MultiVersionNote=Some components are corrupt in more than one version. Each version comes from a different update, so the repair needs an image from each of those updates. The targeted pass looks for them in the kit."
  call :Log "Corrupt in more than one version:!MultiComponents!"
  call :Log "!MultiVersionNote!"
)
:: An older environment that could not load the install's own offline servicing
:: stack may misread the store, so its corruption findings are suspect.
set "StackFailed="
findstr /i /l /c:"cmsofflineservicing" "%LogFile%" 2>nul | findstr /i /l /c:"Failed to load" >nul && set "StackFailed=1"
if defined StackFailed if !HostBuild! LSS !BranchNum! (
  set "OldEnvNote=This scan ran from build !HostBuild! against a !BranchNum! install, and the install's offline servicing stack failed to load. These corruption results may be false. Rescan from a build !BranchNum! or newer WinPE before acting on them."
  call :Log "!OldEnvNote!"
)
exit /b 0

:: :DismVersion  - sets DismVer and DismBuild for the dism.exe found first on PATH
:DismVersion
set "DismVer=unknown"
set "DismBuild=0"
for /f "tokens=2 delims=: " %%v in ('dism /English /? 2^>nul ^| findstr /b /c:"Version:"') do set "DismVer=%%v"
for /f "tokens=3 delims=." %%b in ("!DismVer!") do set /a "DismBuild=%%b" 2>nul
exit /b 0

:: :UseKitDism  - switches to the kit's ADK DISM in DISM\<arch>: installs its mount
:: drivers, as Microsoft's "Copy DISM to another computer" requires on each boot,
:: and puts it first on PATH so every later dism call uses it.
:UseKitDism
set "KitDism=!Root!DISM\!HostArch!"
set "KitDismNote="
if exist "!KitDism!\VERSION.txt" for /f "usebackq tokens=1,* delims==" %%a in ("!KitDism!\VERSION.txt") do if /i "%%a"=="DISM" set "KitDismNote=%%b"
call :Log "Built-in DISM !DismVer! is older than branch !BranchNum!. Switching to the kit DISM in !KitDism!, VERSION.txt says !KitDismNote!"
for %%W in ("!KitDism!\wimmountadksetup*.exe") do (
  "%%~fW" /Install /q
  call :LogRc "Driver install %%~nxW"
)
set "BuiltInDismVer=!DismVer!"
set "PATH=!KitDism!;!PATH!"
call :DismVersion
if !DismBuild! EQU 0 (
  call :Say "The kit's DISM in !KitDism! would not run. Staying with the built-in DISM."
  set "PATH=!PATH:*;=!"
  call :DismVersion
  exit /b 0
)
call :Say "Using the kit's DISM !DismVer! instead of the built-in !BuiltInDismVer!."
exit /b 0

:: ===========================================================================
::  Pass 2: targeted repair
:: ===========================================================================

:: :ScanSource  - sets ScanSrc to the log holding this run's CBS corruption lines:
:: the DISM log offline, a copy of the system's CBS.log online.
:ScanSource
set "ScanSrc=!LogFile!"
if not "!Status!"=="Online" exit /b 0
copy /y "%SystemRoot%\Logs\CBS\CBS.log" "%TEMP%\AutoDISM_cbs_scan.log" >nul 2>&1
if exist "%TEMP%\AutoDISM_cbs_scan.log" set "ScanSrc=%TEMP%\AutoDISM_cbs_scan.log"
exit /b 0

:: :LastScan "<log>" "<out>"  - writes the "(p) CSI Payload Corrupt" lines from the
:: most recent corruption scan in <log> only, so earlier passes and older CBS.log
:: history are not counted. Uses line numbers rather than MORE, which stalls on
:: files over 65535 lines.
:LastScan
set "LastStart=0"
type nul > "%~2"
if not exist "%~1" exit /b 0
for /f "delims=:" %%n in ('findstr /n /l /c:"Starting corruption detection" "%~1" 2^>nul') do set "LastStart=%%n"
for /f "tokens=1* delims=:" %%a in ('findstr /n /l /c:"(p)	CSI Payload Corrupt" "%~1" 2^>nul') do (
  if %%a GTR !LastStart! >>"%~2" echo(%%b
)
exit /b 0

:: :CollectNeeded  - turns the last scan's corrupt files into a sorted list of
:: distinct component folders: "<build> <UBR> <folder>", e.g.
:: 26100 1591 amd64_userexperience-desktop_31bf3856ad364e35_10.0.26100.1591_none_c815e77f1a5104dd
:CollectNeeded
set "NeededCount=0"
for /f "delims==" %%v in ('set NF_ 2^>nul') do set "%%v="
type nul > "%TEMP%\AutoDISM_needed.txt"
call :ScanSource
call :LastScan "!ScanSrc!" "%TEMP%\AutoDISM_corrupt.txt"
for /f "usebackq tokens=4 delims=	" %%c in ("%TEMP%\AutoDISM_corrupt.txt") do (
  for /f "tokens=1 delims=\" %%f in ("%%c") do (
    if not defined NF_%%f (
      set "NF_%%f=1"
      set /a "NeededCount+=1"
      for /f "tokens=4 delims=_" %%v in ("%%f") do for /f "tokens=3,4 delims=." %%x in ("%%v") do >>"%TEMP%\AutoDISM_needed.txt" echo %%x %%y %%f
    )
  )
)
sort "%TEMP%\AutoDISM_needed.txt" /o "%TEMP%\AutoDISM_needed.txt"
exit /b 0

:: :TargetedRepair  - pass 2. Picks one kit image per needed component version,
:: mounts them all, checks the needed folders are really there, then runs one
:: RestoreHealth with every mounted image as a source.
:TargetedRepair
echo.
call :Say "[2/3] Pass 2: matching kit images to the component versions DISM could not find..."
call :CollectNeeded
call :Log "Component versions DISM could not repair: !NeededCount!"
if !NeededCount! EQU 0 (
  call :Say "   DISM did not list any missing component files, so there is nothing to target."
  exit /b 0
)
set "Targeted=1"
call :AppendFile "%TEMP%\AutoDISM_needed.txt" "Needed component versions: build UBR folder"

type nul > "%TEMP%\AutoDISM_plan.txt"
set "LastPair="
for /f "usebackq tokens=1,2" %%a in ("%TEMP%\AutoDISM_needed.txt") do (
  if not "%%a.%%b"=="!LastPair!" (
    set "LastPair=%%a.%%b"
    call :PickSource %%a %%b
  )
)
call :AppendFile "%TEMP%\AutoDISM_plan.txt" "Images chosen: build UBR format index"

call :UnmountSource
set "MountCount=0"
set "SourceArgs="
set "SourceList="
set "LastPlanKey="
for /f "usebackq tokens=1-4" %%a in ("%TEMP%\AutoDISM_plan.txt") do call :MountPlanned %%a %%b %%c %%d

set "Covered=0"
type nul > "%TEMP%\AutoDISM_uncovered.txt"
for /f "usebackq tokens=1-3" %%a in ("%TEMP%\AutoDISM_needed.txt") do call :CheckCovered %%c %%a.%%b
call :Say "   Mounted kit images hold !Covered! of the !NeededCount! needed component versions."
for /f "usebackq tokens=1" %%a in ("%TEMP%\AutoDISM_uncovered.txt") do (
  if not defined MU_%%a (
    set "MU_%%a=1"
    set "MissingList=!MissingList! %%a"
  )
)
if defined MissingList call :AppendFile "%TEMP%\AutoDISM_uncovered.txt" "Needed versions no kit image holds: build.UBR folder"

if !Covered! EQU 0 (
  call :UnmountSource
  exit /b 0
)
if !MountCount! EQU 1 if "!LastPlanKey!"=="!Pass1Key!" if !Covered! EQU !NeededCount! (
  call :Say "   Pass 1's image already holds every needed version, so missing files are not what failed."
  call :Say "   See the DISM error lines in the run log."
  call :UnmountSource
  exit /b 0
)

call :Say "   Running one repair with !MountCount! mounted image(s) as sources..."
call :Log "Targeted RestoreHealth /LimitAccess with:!SourceList!"
dism !DismCommon! /Cleanup-Image /RestoreHealth !SourceArgs! /LimitAccess
call :LogRc "Targeted RestoreHealth /LimitAccess"
set "RestoreRc=!rc!"
set "RestoreHex=!RcHex!"
call :UnmountSource
set "rc=!RestoreRc!"
set "RcHex=!RestoreHex!"
if "!rc!"=="0"    set "Repaired=1"
if "!rc!"=="3010" set "Repaired=1"
if not defined Repaired echo    The targeted repair did not complete ^(!RcHex!^).
exit /b 0

:: :PickSource <build> <UBR>  - finds the kit image with that exact UBR, or else the
:: nearest newer one, that has the install's edition. A component version is
:: carried by every image from its update until the component changes again, so
:: the nearest newer image is the best second choice.
:PickSource
set "PB=%~1"
set "PV="
set /a "PV=%~2" 2>nul
if not "!PV!"=="%~2" exit /b 0
type nul > "%TEMP%\AutoDISM_pick.txt"
if exist "!Root!Source\!PB!\" (
  for %%X in (WIM ESD SWM) do for %%F in ("!Root!Source\!PB!\!PB!.*.!TargetArch!.%%X") do (
    for /f "tokens=2 delims=." %%u in ("%%~nF") do call :PickAdd %%u %%X
  )
)
sort "%TEMP%\AutoDISM_pick.txt" /o "%TEMP%\AutoDISM_pick.txt"
set "Picked="
for /f "usebackq tokens=2,3" %%a in ("%TEMP%\AutoDISM_pick.txt") do if not defined Picked call :PickTry %%a %%b
if not defined Picked call :Log "  needs !PB!.!PV!: no kit image at or after that UBR has edition !Edition!"
exit /b 0

:: :PickAdd <UBR> <Ext>  - adds one image at or after the needed UBR, nearest first
:PickAdd
set "PU="
set /a "PU=%~1" 2>nul
if not "!PU!"=="%~1" exit /b 0
if !PU! LSS !PV! exit /b 0
set /a "PD=PU-PV"
set "PP=000000!PD!"
set "PP=!PP:~-6!"
set "PO=3"
if /i "%~2"=="WIM" set "PO=1"
if /i "%~2"=="ESD" set "PO=2"
>>"%TEMP%\AutoDISM_pick.txt" echo !PP!!PO! %~1 %~2
exit /b 0

:: :PickTry <UBR> <Ext>  - accepts the image if it has the edition
:PickTry
set "PKey=!PB!.%~1.%~2"
if defined PL_!PKey! (
  set "Picked=1"
  call :Log "  needs !PB!.!PV!: covered by !PKey!, already chosen"
  exit /b 0
)
set "SrcFile=!Root!Source\!PB!\!PB!.%~1.!TargetArch!.%~2"
call :FindIndex
if not defined MatchIndex exit /b 0
set "PL_!PKey!=1"
>>"%TEMP%\AutoDISM_plan.txt" echo !PB! %~1 %~2 !MatchIndex!
set "Picked=1"
if "%~1"=="!PV!" (
  call :Log "  needs !PB!.!PV!: exact image !PKey!"
) else (
  call :Log "  needs !PB!.!PV!: nearest newer image !PKey!"
)
exit /b 0

:: :MountPlanned <build> <UBR> <Ext> <Index>  - mounts one chosen image read-only
:: at Mount1, Mount2, ... exporting ESD and split images to a WIM first.
:MountPlanned
if !MountCount! GEQ 8 (
  call :Log "  Not mounting %~1.%~2.%~3: the limit of 8 mounts was reached"
  exit /b 0
)
set /a "MN=MountCount+1"
set "MP=!ScratchDir!\Mount!MN!"
set "SrcDir=!Root!Source\%~1"
set "SrcBase=%~1.%~2.!TargetArch!"
set "SrcFile=!SrcDir!\!SrcBase!.%~3"
set "ImageToUse=!SrcFile!"
set "IndexToUse=%~4"
if /i not "%~3"=="WIM" (
  echo    Exporting !SrcBase!.%~3 index %~4 to a temporary WIM...
  if exist "!ScratchDir!\source!MN!.wim" del /f /q "!ScratchDir!\source!MN!.wim" >nul 2>&1
  if /i "%~3"=="SWM" (
    dism /English /Export-Image /SourceImageFile:"!SrcFile!" /SWMFile:"!SrcDir!\!SrcBase!*.SWM" /SourceIndex:%~4 /DestinationImageFile:"!ScratchDir!\source!MN!.wim" /Compress:fast
  ) else (
    dism /English /Export-Image /SourceImageFile:"!SrcFile!" /SourceIndex:%~4 /DestinationImageFile:"!ScratchDir!\source!MN!.wim" /Compress:fast
  )
  call :LogRc "Export-Image of !SrcBase!.%~3"
  if not "!rc!"=="0" (
    call :Say "   Could not export !SrcBase!.%~3. Skipping it."
    exit /b 0
  )
  set "ImageToUse=!ScratchDir!\source!MN!.wim"
  set "IndexToUse=1"
)
echo    Mounting !SrcBase!.%~3 read-only...
mkdir "!MP!" >nul 2>&1
dism /English /Mount-Image /ImageFile:"!ImageToUse!" /Index:!IndexToUse! /MountDir:"!MP!" /ReadOnly
call :LogRc "Mount-Image !SrcBase!.%~3 at Mount!MN!"
if not "!rc!"=="0" (
  call :Say "   Could not mount !SrcBase!.%~3. Skipping it."
  exit /b 0
)
set "MountCount=!MN!"
set "LastPlanKey=%~1.%~2.%~3"
set "SourceArgs=!SourceArgs! /Source:"!MP!\Windows""
set "SourceList=!SourceList! !SrcBase!.%~3"
exit /b 0

:: :CheckCovered <folder> <build.UBR>  - counts the folder as covered if any
:: mounted image has it in WinSxS, the exact place DISM looks.
:CheckCovered
for /d %%M in ("%ScratchDir%\Mount*") do if exist "%%M\Windows\WinSxS\%~1\" (
  set /a "Covered+=1"
  exit /b 0
)
>>"%TEMP%\AutoDISM_uncovered.txt" echo %~2 %~1
exit /b 0

:: ===========================================================================
::  Pass 3: remove superseded copies
:: ===========================================================================

:: :ResetBasePass  - offered only when every damaged component version has a newer
:: version installed alongside it. Asks first, default No.
:ResetBasePass
call :CollectNeeded
if !NeededCount! EQU 0 exit /b 0
set "SupersededCount=0"
for /f "usebackq tokens=3" %%f in ("%TEMP%\AutoDISM_needed.txt") do call :CheckSuperseded %%f
call :Log "Damaged component versions with a newer version installed: !SupersededCount! of !NeededCount!"
if !SupersededCount! LSS !NeededCount! (
  call :Log "Pass 3 not offered: some damaged versions are the ones Windows uses."
  exit /b 0
)
echo.
call :Say "[2/3] Pass 3: every damaged file is in an old copy kept only for uninstalling updates."
echo    StartComponentCleanup /ResetBase deletes all of those old copies, which removes the
echo    corruption without needing a source image. Afterward, updates that are already
echo    installed can no longer be uninstalled. This cannot be undone.
choice /c YN /n /t 120 /d N /m "   Remove the old copies? Y/N, defaults to N in 2 minutes: "
if errorlevel 2 (
  call :Log "Pass 3 declined: ResetBase was not run"
  exit /b 0
)
call :Log "Pass 3 approved: running StartComponentCleanup /ResetBase"
echo    Removing old component copies. This can take a while...
dism !DismCommon! /Cleanup-Image /StartComponentCleanup /ResetBase
call :LogRc "StartComponentCleanup /ResetBase"
if not "!rc!"=="0" (
  call :Say "   ResetBase did not complete, code !RcHex!. A pending update can block it; see the pending list in the run log."
  exit /b 0
)
echo    Checking the component store again...
dism !DismCommon! /Cleanup-Image /RestoreHealth /LimitAccess
call :LogRc "RestoreHealth after ResetBase"
if "!rc!"=="0"    set "Repaired=1"
if "!rc!"=="3010" set "Repaired=1"
if defined Repaired (
  call :Say "   The component store is healthy after removing the old copies."
) else (
  call :Say "   Corruption remains after ResetBase, code !RcHex!. See the run log."
)
exit /b 0

:: :CheckSuperseded <folder>  - counts the damaged component folder as superseded
:: when the install's WinSxS holds a newer version of the same component: same
:: architecture, name, key and culture, higher build or UBR.
:CheckSuperseded
set "SArch=" & set "SName=" & set "SKey=" & set "SVer=" & set "SCult="
for /f "tokens=1-5 delims=_" %%a in ("%~1") do (
  set "SArch=%%a"
  set "SName=%%b"
  set "SKey=%%c"
  set "SVer=%%d"
  set "SCult=%%e"
)
if not defined SCult exit /b 0
set "SB=0" & set "SU=0"
for /f "tokens=3,4 delims=." %%x in ("!SVer!") do (
  set "SB=%%x"
  set "SU=%%y"
)
set "SPat=!Drive!:\Windows\WinSxS\!SArch!_!SName!_!SKey!_*_!SCult!_*"
set "Newer="
for /d %%D in ("%SPat%") do (
  for /f "tokens=4 delims=_" %%v in ("%%~nxD") do for /f "tokens=3,4 delims=." %%x in ("%%v") do (
    if %%x GTR !SB! set "Newer=1"
    if %%x EQU !SB! if %%y GTR !SU! set "Newer=1"
  )
)
if defined Newer (
  set /a "SupersededCount+=1"
) else (
  call :Log "  No newer installed version of %~1"
)
exit /b 0
