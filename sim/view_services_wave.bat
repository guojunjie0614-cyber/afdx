@echo off
setlocal
pushd "%~dp0.."

if not exist "rtl\AFDX_top.v" (
    echo [ERROR] Cannot find rtl\AFDX_top.v under "%CD%".
    popd
    pause
    exit /b 1
)

set "VSIM="
if defined MODELSIM_HOME (
    if exist "%MODELSIM_HOME%\vsim.exe" set "VSIM=%MODELSIM_HOME%\vsim.exe"
    if not defined VSIM if exist "%MODELSIM_HOME%\win64\vsim.exe" set "VSIM=%MODELSIM_HOME%\win64\vsim.exe"
)
if not defined VSIM (
    for /f "delims=" %%I in ('where vsim.exe 2^>nul') do (
        if not defined VSIM set "VSIM=%%~fI"
    )
)
if not defined VSIM (
    for /f "delims=" %%I in ('where modelsim.exe 2^>nul') do (
        if not defined VSIM if exist "%%~dpIvsim.exe" set "VSIM=%%~dpIvsim.exe"
    )
)

if not defined VSIM (
    echo [ERROR] ModelSim vsim.exe not found.
    echo Please add ModelSim win64 directory to PATH, or set MODELSIM_HOME.
    popd
    pause
    exit /b 1
)

echo Launching ModelSim GUI for 5-service integrated waveform (sim/run_services.do)...
start "" "%VSIM%" -gui -do "do sim/run_services.do"
popd
exit /b 0
