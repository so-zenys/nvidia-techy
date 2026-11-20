@echo off
setlocal EnableExtensions
title SYNEZ - NVIDIA GPU Tweaks

:: =====================================================================
::  SYNEZ NVIDIA GPU Tweaks
::  Target : GTX 16 / RTX 20-50 series, R570+ drivers, Win11 24H2+
::  Reboot required after running. Re-run after every clean driver
::  install (it wipes the Class\{...}\000X adapter keys).
:: =====================================================================

:: ---- Build config (bump per build) ----------------------------------
set "NVAPP_URL=https://us.download.nvidia.com/nvapp/client/11.0.9.585/x64/NVIDIA_app_v11.0.9.585_x64.exe"
set "NIP_URL=https://raw.githubusercontent.com/synez-os/nvidia/refs/heads/main/synez_nv_profile_v10.nip"
set "NPI_URL=https://github.com/Orbmu2k/nvidiaProfileInspector/releases/latest/download/nvidiaProfileInspector.zip"

set "LOG=C:\Temp\synez-nvidia-log.txt"
if not exist "C:\Temp" mkdir "C:\Temp" >nul 2>&1
set "CLASS=HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}"
set "NPI_DIR=%temp%\SynezNPI"
set "FOUND=0"

>>"%LOG%" echo.
>>"%LOG%" echo ==== SYNEZ NVIDIA GPU Tweaks  %date% %time% ====

echo Applying Synez Custom NVIDIA Profile

:: ---------------------------------------------------------------------
:: 1. NVIDIA APP (silent, pinned)
::    Installed as the logged-in user, not SYSTEM (see below). Waits for
::    any NVIDIA driver setup still running, installs, then CHECKS the
::    app actually landed and logs the real result.
:: ---------------------------------------------------------------------
echo Installing NVIDIA App
set "NVAPP_DIR=C:\Windows\Temp\SynezNvApp"
set "NVAPP_EXE=%NVAPP_DIR%\nvidia_app.exe"
:: clear a stuck copy left by an older run (only our pinned exe name, never a manual download)
taskkill /f /im nvidia_app.exe >nul 2>&1
schtasks /delete /tn SynezNvApp /f >nul 2>&1
rmdir /s /q "%NVAPP_DIR%" >nul 2>&1
mkdir "%NVAPP_DIR%" >nul 2>&1

:: let a still-running NVIDIA driver/setup process finish first (max 3 min)
powershell -NoProfile -Command "$t=0; while($t -lt 180 -and (Get-Process | Where-Object { $_.Company -like 'NVIDIA*' -and $_.ProcessName -match 'setup|install|nvi2' })){ Start-Sleep 3; $t+=3 }" >nul 2>&1

curl -f -s -L -o "%NVAPP_EXE%" "%NVAPP_URL%"
if not exist "%NVAPP_EXE%" (
    >>"%LOG%" echo [FAIL] NVIDIA App download failed, skipped
    goto :NVAPP_DONE
)
:: The module runs as SYSTEM in session 0. NVIDIA's installer hangs there forever,
:: and while it hangs every other copy of the installer exits instantly (rc 5).
:: So: run it as the logged-in user (highest privileges) via a one-shot task,
:: wait for it to finish, delete the task.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$e=Get-CimInstance Win32_Process | ? { $_.Name -eq 'explorer.exe' -and $_.SessionId -ne 0 } | select -First 1; $u=$null; if($e){ $o=Invoke-CimMethod -InputObject $e -MethodName GetOwner; if($o.User){ $u=$o.Domain+'\'+$o.User } }; if(-not $u){ $u=(Get-CimInstance Win32_ComputerSystem).UserName }; if(-not $u){ exit 3 }; $a=New-ScheduledTaskAction -Execute '%NVAPP_EXE%' -Argument '-s -noreboot -noeula -nofinish -nosplash'; $pr=New-ScheduledTaskPrincipal -UserId $u -LogonType Interactive -RunLevel Highest; $st=New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 20); Register-ScheduledTask -TaskName 'SynezNvApp' -Action $a -Principal $pr -Settings $st -Force | Out-Null; Start-ScheduledTask -TaskName 'SynezNvApp'; Start-Sleep 3; $t=0; while($t -lt 900 -and (Get-ScheduledTask -TaskName 'SynezNvApp').State -eq 'Running'){ Start-Sleep 3; $t+=3 }; $rc=(Get-ScheduledTaskInfo -TaskName 'SynezNvApp').LastTaskResult; Unregister-ScheduledTask -TaskName 'SynezNvApp' -Confirm:$false; exit $rc"
set "NVRC=%errorlevel%"
if "%NVRC%"=="3" >>"%LOG%" echo [FAIL] NVIDIA App: no logged-in user found to install as
:: the installer can hand off to a child process and return early - give it up to 60s to land
set /a NVTRY=0
:NVAPP_WAIT
call :NVAPP_CHECK
if "%NVAPP_IN%"=="1" goto :NVAPP_RESULT
set /a NVTRY+=1
if %NVTRY% lss 12 (timeout /t 5 /nobreak >nul & goto :NVAPP_WAIT)
:NVAPP_RESULT
if "%NVAPP_IN%"=="1" (
    >>"%LOG%" echo [OK]   NVIDIA App installed (rc %NVRC%^)
) else (
    >>"%LOG%" echo [FAIL] NVIDIA App did not install (rc %NVRC%^)
)
rmdir /s /q "%NVAPP_DIR%" >nul 2>&1
:NVAPP_DONE

:: ---------------------------------------------------------------------
:: 2. NVIDIA PROFILE INSPECTOR: import SYNEZ base profile
::    Single-line calls on purpose: a ^ continuation escapes the first
::    char of the next line, so a leading quote gets eaten and the
::    trailing >nul 2>&1 ended up passed to NPI as arguments.
:: ---------------------------------------------------------------------
echo Importing SYNEZ NVIDIA profile
rmdir /s /q "%NPI_DIR%" >nul 2>&1
curl -f -s -L -o "%temp%\nvidiaProfileInspector.zip" "%NPI_URL%"
powershell -NoProfile -Command "Expand-Archive -Path '%temp%\nvidiaProfileInspector.zip' -DestinationPath '%NPI_DIR%' -Force" >nul 2>&1
del /f /q "%temp%\nvidiaProfileInspector.zip" >nul 2>&1

:: Locate exe regardless of zip structure (root or nested folder)
set "NPI_EXE="
for /f "delims=" %%E in ('dir /s /b "%NPI_DIR%\nvidiaProfileInspector.exe" 2^>nul') do set "NPI_EXE=%%E"

curl -f -s -L -o "%NPI_DIR%\synez_nv_profile.nip" "%NIP_URL%"

taskkill /f /im nvidiaProfileInspector.exe >nul 2>&1
if not defined NPI_EXE (
    >>"%LOG%" echo [FAIL] NPI exe not found after extract
) else if not exist "%NPI_DIR%\synez_nv_profile.nip" (
    >>"%LOG%" echo [FAIL] .nip download failed
) else (
    :: -silentImport required since the NPI 3.0 rewrite (dialog otherwise)
    start "" /wait "%NPI_EXE%" -silentImport "%NPI_DIR%\synez_nv_profile.nip"
    >>"%LOG%" echo [OK]   SYNEZ profile imported
)
taskkill /f /im nvidiaProfileInspector.exe >nul 2>&1
rmdir /s /q "%NPI_DIR%" >nul 2>&1

:: ---------------------------------------------------------------------
:: 3. MSI MODE
::    Message Signaled Interrupts: lower interrupt latency, no IRQ
::    sharing. DevicePriority removed (undefined), same as main.bat.
:: ---------------------------------------------------------------------
for /f "tokens=*" %%i in ('powershell -NoProfile -Command "Get-PnpDevice -Class Display -PresentOnly | Where-Object { $_.InstanceId -like 'PCI\VEN_*' } | Select-Object -ExpandProperty InstanceId"') do (
    reg add "HKLM\SYSTEM\CurrentControlSet\Enum\%%i\Device Parameters\Interrupt Management\MessageSignaledInterruptProperties" /v MSISupported /t REG_DWORD /d 1 /f >nul 2>&1 && (>>"%LOG%" echo [OK]   MSI on  %%i) || (>>"%LOG%" echo [FAIL] MSI on  %%i)
    reg delete "HKLM\SYSTEM\CurrentControlSet\Enum\%%i\Device Parameters\Interrupt Management\Affinity Policy" /v DevicePriority /f >nul 2>&1
)

:: ---------------------------------------------------------------------
:: 4. PER-ADAPTER DRIVER KEYS
::    Find every Class\000X key whose ProviderName is NVIDIA instead of
::    assuming \0000 (iGPU often takes 0000 on Intel / AM5).
:: ---------------------------------------------------------------------
echo Applying GPU Tweaks
for /f "delims=" %%k in ('reg query "%CLASS%" /s /v "ProviderName" 2^>nul ^| findstr /r /c:"\\[0-9][0-9][0-9][0-9]$"') do (
    reg query "%%k" /v "ProviderName" 2>nul | findstr /i /c:"NVIDIA" >nul && call :NV "%%k"
)
if "%FOUND%"=="0" >>"%LOG%" echo [WARN] No NVIDIA adapter key found. Install the driver first.

:: ---------------------------------------------------------------------
:: 5. GLOBAL DRIVER + OS GRAPHICS KEYS
:: ---------------------------------------------------------------------
:: Legacy GFE backend autostart
reg delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v NvBackend /f >nul 2>&1

:: Display power saving off (panel-side power features driven by the driver)
call :DW "HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm\Global\NVTweak" "DisplayPowerSaving" 0

:: HD Audio (HDMI/DP) function never drops to D3cold
call :DW "HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm" "EnableHDAudioD3Cold" 0

:: Spread driver DPCs across CPU cores instead of piling on core 0.
:: Written to the service key here and the adapter key in :NV.
call :DW "HKLM\SYSTEM\CurrentControlSet\Services\nvlddmkm" "RmGpsPsEnablePerCpuCoreDpc" 1

:: Stray global copy of DisableDynamicPstate (older main.bat wrote it here)
reg delete "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" /v "DisableDynamicPstate" /f >nul 2>&1

:: Hardware-accelerated GPU scheduling ON. Required for DLSS Frame Gen /
:: Multi Frame Gen on RTX 40/50, and the default on current drivers.
call :DW "HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers" "HwSchMode" 2

:: MPO back to Windows default (MPO = independent flip in borderless)
reg delete "HKLM\SOFTWARE\Microsoft\Windows\Dwm" /v OverlayTestMode /f >nul 2>&1
>>"%LOG%" echo [OK]   MPO default

:: "Optimizations for windowed games": upgrades legacy DX10/11 blt-model
:: windowed/borderless games to flip model = lower present latency,
:: tear-free borderless. Per-user (HKCU of whoever runs this).
call :SZ "HKCU\Software\Microsoft\DirectX\UserGpuPreferences" "DirectXUserGlobalSettings" "SwapEffectUpgradeEnable=1;"

:: ---------------------------------------------------------------------
:: 6. NVIDIA BLOAT + TELEMETRY
:: ---------------------------------------------------------------------
echo Disabling NVIDIA bloat

:: FrameView SDK (FvSvc) and legacy telemetry container
for %%s in (FvSvc NvTelemetryContainer) do (
    sc stop %%s >nul 2>&1
    sc config %%s start= disabled >nul 2>&1 && (>>"%LOG%" echo [OK]   service disabled %%s) || (>>"%LOG%" echo [SKIP] service %%s not present)
)

:: Driver telemetry opt-out flags
call :DW "HKLM\SOFTWARE\NVIDIA Corporation\NvControlPanel2\Client" "OptInOrOutPreference" 0
call :DW "HKLM\SOFTWARE\NVIDIA Corporation\Global\FTS" "EnableRID44231" 0
call :DW "HKLM\SOFTWARE\NVIDIA Corporation\Global\FTS" "EnableRID64640" 0
call :DW "HKLM\SOFTWARE\NVIDIA Corporation\Global\FTS" "EnableRID66610" 0

:: Scheduled tasks (GUID suffixes vary, match by name, never hardcode):
::   *SelfUpdate*          NVIDIA App self updater
::   NvTmRep*              crash/telemetry reporting
::   NvDriverUpdateCheck*  daily driver update check
::   NvProfileUpdater*     cloud game-profile updates (can touch DRS)
::   NvNodeLauncher*       legacy GFE node
powershell -NoProfile -Command "Get-ScheduledTask | ? { $_.TaskName -like 'NvTmRep*' -or $_.TaskName -like 'NvDriverUpdateCheck*' -or $_.TaskName -like 'NvProfileUpdater*' -or $_.TaskName -like 'NvNodeLauncher*' -or (($_.TaskName -like '*SelfUpdate*') -and (($_.TaskName -like '*Nvidia*') -or ($_.TaskPath -like '*NVIDIA*'))) } | Disable-ScheduledTask | Out-Null" >nul 2>&1
>>"%LOG%" echo [OK]   NVIDIA tasks disabled

:: ---------------------------------------------------------------------
:: 7. POWER PLAN: PCIe Link State Power Management OFF
::    Stops the GPU PCIe link dropping to L0s/L1 between frames.
:: ---------------------------------------------------------------------
powercfg /setacvalueindex scheme_current SUB_PCIEXPRESS ASPM 0 >nul 2>&1
powercfg /setdcvalueindex scheme_current SUB_PCIEXPRESS ASPM 0 >nul 2>&1
powercfg /setactive scheme_current >nul 2>&1
>>"%LOG%" echo [OK]   PCIe ASPM off (active plan)

echo Done. Reboot to apply.
>>"%LOG%" echo ==== Done ====
timeout /t 2 /nobreak >nul
exit


:: =====================================================================
::  Per-adapter tweaks. %~1 = Class\{...}\000X key of an NVIDIA adapter
:: =====================================================================
:NV
set "FOUND=1"
set "K=%~1"
>>"%LOG%" echo --- Adapter: %K%

:: SYNEZ driver power profile:
::   P-state lock (DisableDynamicPstate=1 keeps P0, higher idle power/temps),
::   clock/power gating + GC6/ELPG off, GPU-side ASPM off, runtime PM off,
::   HDCP off (DRM streaming like Netflix drops to low res / may not play),
::   EDC/ECC paths off, flip collapse + immediate flip reporting on.
for %%V in (
    "RmPowerFeature 0x54455565"
    "RmPowerFeature2 0x5555555"
    "D3PCLatency 1"
    "EnablePerformanceMode 1"
    "EnableRuntimePowerManagement 0"
    "DisableDynamicPstate 1"
    "EnableMsHybrid 0"
    "RMElcg 0x55555554"
    "RMGC6Feature 0xaaaaa"
    "RMGC6Parameters 0x55"
    "RMGCOffFeature 1"
    "RMDidleFeatureGC5 0x2aa8aaa"
    "RMD3Feature 2"
    "RMClkSlowDown 0x4400000"
    "RmOptp2LowerMclk 0"
    "RmOverrideIdleSlowdownSettings 0"
    "RmClkPowerOffDramPllWhenUnused 0"
    "RMLpwrArch 0x55555"
    "RMLpwrEiClient 5"
    "RmLpwrCtrlGrRgParameters 0x5555555"
    "RmLpwrCtrlMsDifrCgParameters 0x555"
    "RmLpwrCtrlMsDifrSwAsrParameters 0x1555"
    "RmLpwrCtrlMsLtcParameters 5"
    "RmLpwrGrPgSwFilterFunction 0"
    "RmLpwrCacheStatsOnD3 0"
    "RmDwbMscg 1"
    "SlideMCLK 0"
    "RMEnableASPMAtLoad 0"
    "RMDisableGpuASPMFlags 3"
    "RMDisableOptimalPowerForPadlinkPll 1"
    "RMForceRtd3D3Hot 2"
    "RmMIONoPowerOff 1"
    "RM2644249 1"
    "RM303107 0x10"
    "RM2779240 5"
    "RM580312 1"
    "RMBug2519005War 1"
    "RmCeElcgWar1895530 1"
    "RmWar1760398 1"
    "RMOPSB 0x2aa2"
    "RmDisableInforomBBX 0xf"
    "RmPgCtrlParameters 0x55555155"
    "RmPgCtrlGrParameters 0x55555555"
    "RMElpgStateOnInit 3"
    "RmDisableACPI 0x3ff"
    "RMDisablePostL2Compression 1"
    "RMDisableNoncontigAlloc 1"
    "RMBandwidthFeature 0x7103c400"
    "RMBandwidthFeature2 1"
    "PreferSystemMemoryContiguous 1"
    "RMDisableEDC 1"
    "RMDisableIntrIllegalCompstatAccess 1"
    "RMDisableLRCCoalescing 1"
    "RmDisableHwFaultBuffer 1"
    "RMHdcpKeyglobZero 1"
    "RmDisableHdcp22 1"
    "RMEnableL1ECC 0"
    "RMEnableSMECC 0"
    "RMEnableSHMECC 0"
    "RMAssertOnEccErrors 0"
    "enableRS2FlipCollapse 1"
    "enableRS2ImmediateFlipCompletionReporting 1"
    "DP2X_IGNORE_CABLE_ID_CAPS 1"
    "RmCacheLoc 0"
    "RmDisableInst2Sys 1"
    "RmFbsrPagedDMA 1"
) do for /f "tokens=1,2" %%a in (%%V) do call :DW "%K%" "%%a" "%%b"

:: Per-core DPC distribution (adapter-scoped copy)
call :DW "%K%" "RmGpsPsEnablePerCpuCoreDpc" 1
exit /b


:: =====================================================================
::  Helpers: write value + log result
:: =====================================================================
:DW
reg add "%~1" /v "%~2" /t REG_DWORD /d "%~3" /f >nul 2>&1 && (>>"%LOG%" echo [OK]   %~2 = %~3) || (>>"%LOG%" echo [FAIL] %~2)
exit /b

:SZ
reg add "%~1" /v "%~2" /t REG_SZ /d "%~3" /f >nul 2>&1 && (>>"%LOG%" echo [OK]   %~2 = "%~3") || (>>"%LOG%" echo [FAIL] %~2)
exit /b


:: =====================================================================
::  NVIDIA App helpers
:: =====================================================================
:NVAPP_CHECK
set "NVAPP_IN=0"
for /f "delims=" %%A in ('dir /s /b "%ProgramFiles%\NVIDIA Corporation\NVIDIA app\NVIDIA app.exe" 2^>nul') do set "NVAPP_IN=1"
reg query "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall" /s /f "NVIDIA app" /d >nul 2>&1 && set "NVAPP_IN=1"
exit /b

