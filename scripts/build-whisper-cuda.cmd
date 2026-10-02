@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================================
rem build-whisper-cuda.cmd - self-contained CUDA 12.9 sm_75 whisper-cli build
rem
rem Design constraints (learned the hard way):
rem   * NO bare '(' or stray '%' inside parenthesized 'if ( ... )' blocks; cmd
rem     validates syntax for the whole block BEFORE executing any branch, so
rem     any unescaped '(' or stray '%' there kills the script.
rem   * Use goto-based error handlers: 'goto :err_<name>' to a label at the
rem     bottom of the file where the diagnostic text lives at top level.
rem   * vcvarsall's env persists only within THIS batch - keep vswhere/
rem     vcvarsall/configure/build all in this one file so the env survives
rem     to nvcc + cl.
rem ============================================================================

echo [build] === toolchain discovery ===

rem --- locate vswhere ---------------------------------------------------------
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "!VSWHERE!" goto have_vswhere
set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "!VSWHERE!" goto have_vswhere
goto :err_no_vswhere

:have_vswhere
echo [vs] using "!VSWHERE!"

rem --- locate a VS install with x64 C++ component -----------------------------
set "VSPATH="
for /f "usebackq delims=" %%i in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"
if defined VSPATH goto :have_vs
goto :err_no_vs

:have_vs
echo [vs] VS install: !VSPATH!

set "VCVARS=!VSPATH!\VC\Auxiliary\Build\vcvarsall.bat"
if exist "!VCVARS!" goto :have_vcvars
goto :err_no_vcvars

:have_vcvars
call "!VCVARS!" x64
if errorlevel 1 goto :err_vcvars_failed
if defined INCLUDE goto :have_msenv
goto :err_no_msenv

:have_msenv
echo [vs] vcvarsall OK
call where cl

rem --- make CUDA toolkit visible (Jimver exports CUDA_PATH) --------------------
if defined CUDA_PATH goto :have_cuda
goto :err_no_cuda

:have_cuda
set "PATH=%CUDA_PATH%\bin;%PATH%"
if exist "%CUDA_PATH%\bin\cudart64_12.dll" goto :have_cudart
goto :err_no_cudart

:have_cudart
echo [cuda] using CUDA_PATH = %CUDA_PATH%
if exist "%CUDA_PATH_V12_9%\bin\cudart64_12.dll" echo [cuda] CUDA_PATH_V12_9 points at: %CUDA_PATH_V12_9%
if exist "%CUDA_PATH%\bin\cublas64_12.dll" goto :have_cublas
goto :err_no_cublas

:have_cublas
call nvcc --version
if errorlevel 1 goto :err_no_nvcc
echo [cuda] nvcc OK
where cmake
where ninja
if errorlevel 1 goto :err_no_tools

:have_tools
echo [cfg] starting cmake configure for sm_75 / CUDA 12.9

cmake -B build -S upstream -G "Ninja" -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_CUDA_ARCHITECTURES=75 -DGGML_CUDA=ON -DGGML_STATIC=ON ^
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_ALL_WARNINGS=OFF ^
  -DGGML_CUDA_NCCL=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF ^
  -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF -DWHISPER_ALL_WARNINGS=OFF
if errorlevel 1 goto :err_cfg
echo [cfg] configure OK

echo [build] === compiling whisper-cli ===
cmake --build build --target whisper-cli -j %NUMBER_OF_PROCESSORS%
if errorlevel 1 goto :err_build
echo [build] build OK

echo [out] === build/bin contents ===
dir build\bin

if exist "build\bin\whisper-cli.exe" goto :check_cuda_dll
goto :err_no_cli

:check_cuda_dll
if exist "build\bin\ggml-cuda.dll" goto :done
goto :err_no_ggml_cuda

:done
echo [build] SUCCESS
exit /b 0

rem ----------------------------------------------------------------- handlers
:err_no_vswhere
echo [err] vswhere.exe not found at either:
echo         %ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
echo         %ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe
echo       Fix: install VS 2022+ with the "Desktop development with C++" workload.
exit /b 10

:err_no_vs
echo [err] vswhere found but reported NO Visual Studio with the x64 C++ workload.
echo       Run manually to enumerate installs:
echo         "!VSWHERE!" -all -format json
echo       If a VS is listed but missing VC.Tools.x86.x64: repair the install
echo       with vs_installer.exe and add the "Desktop development with C++" workload.
exit /b 11

:err_no_vcvars
echo [err] vcvarsall.bat not found under !VSPATH!.
echo       VS install layout may be unusual - check the folder manually.
exit /b 12

:err_vcvars_failed
echo [err] vcvarsall.bat x64 exited non-zero. Its own output (above this) is
echo       the real error; typically a VS workload inconsistency.
exit /b 13

:err_no_msenv
echo [err] vcvarsall ran but INCLUDE was not set afterward. Run manually to
echo       see what vcvarsall left behind:
echo         "!VCVARS!" x64 ^&^& set
exit /b 14

:err_no_cuda
echo [err] CUDA_PATH is not set. The Jimver/cuda-toolkit step must run BEFORE
echo       this and export CUDA_PATH. Check that step's log.
exit /b 20

:err_no_cudart
echo [err] %CUDA_PATH%\bin\cudart64_12.dll is missing.
echo       Either the Jimver step failed to install CUDA 12.9, or the toolkit
echo       landed in a different folder than %CUDA_PATH%. Verify the installer
echo       output from the Jimver step.
exit /b 21

:err_no_cublas
echo [err] %CUDA_PATH%\bin\cublas64_12.dll is missing.
echo       cuBLAS is required - Windows has NO static cuBLAS lib, so the build
echo       would link against a DLL that does not exist. Check the CUDA 12.9
echo       install is complete (a truncated installer can produce exactly this).
exit /b 22

:err_no_nvcc
echo [err] nvcc is not on PATH even after prepending %CUDA_PATH%\bin.
echo       Check that %CUDA_PATH%\bin actually contains nvcc.exe, or that the
echo       install is complete.
exit /b 23

:err_no_tools
echo [err] cmake and/or ninja are not on PATH. Both should be pre-installed on
echo       GHA windows-latest; confirm the "Install Ninja" step ran successfully.
exit /b 30

:err_cfg
echo [err] cmake configure failed. CMake error output is in the lines above
echo       this (search for "CMake Error" or "CMake Warning").
exit /b 40

:err_build
echo [err] cmake build failed. Search the lines above this for "error C",
echo       "fatal error", "error LNK", or "nvcc fatal".
exit /b 41

:err_no_cli
echo [err] build completed but build\bin\whisper-cli.exe is absent. CMake may
echo       have placed it elsewhere; grep the build log for the whisper-cli.exe
echo       install path.
exit /b 50

:err_no_ggml_cuda
echo [err] build completed but build\bin\ggml-cuda.dll is absent - the CUDA
echo       backend did not compile. Defeats the whole reason for the CUDA 12.9
echo       install; see the build log above for the reason.
exit /b 51
