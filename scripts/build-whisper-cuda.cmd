@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================================
rem build-whisper-cuda.cmd [CUDA|CPU] -- self-contained whisper-cli build
rem
rem CUDA: CUDA 12.9, sm_75 (Turing, RTX 2060), cudart statically linked,
rem       cuBLAS stays a DLL (no static Windows lib exists), examples/tests/
rem       server/SDL2/cURL all off, CPU backend single variant.
rem CPU:  no CUDA at all -- only built for the executable smoke test on the
rem       GPU-less runner (the CUDA binary cannot LAUNCH there: ggml-cuda.dll
rem       imports nvcuda.dll, the NVIDIA driver, which GHA images do not have).
rem
rem Design constraints (learned the hard way):
rem   * NO bare '(' or stray '%' inside parenthesized 'if ( ... )' blocks; cmd
rem     validates syntax for the whole block BEFORE executing any branch.
rem   * goto-based error handlers, diagnostic text at top level.
rem   * vcvarsall's env persists only in THIS batch -- everything stays in here.
rem ============================================================================

set "MODE=%1"
set "BUILDDIR=build"
set "MODE_L="
if /I "%MODE%"=="CPU" set "BUILDDIR=build-cpu"
if /I "%MODE%"=="CPU" set "MODE_L=cpu"
if /I "%MODE%"=="CUDA" set "MODE_L=cuda"
if "!MODE_L!"=="" goto err_bad_mode

echo [build] === toolchain discovery (mode=!MODE_L!) ===

rem --- locate vswhere ---------------------------------------------------------
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "!VSWHERE!" goto have_vswhere
set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "!VSWHERE!" goto have_vswhere
goto :err_no_vswhere

:have_vswhere
echo [vs] using "!VSWHERE!"

rem --- locate a VS 2022 install with x64 C++ component ------------------------
rem NOTE: windows-latest rotated to the VS 2026-only "windows-2025-vs2026" image
rem (no VS 2022 at all). nvcc 12.9 only supports VS 2017..2022, so the workflow
rem pins runs-on: windows-2022, which still ships VS 2022.
set "VSPATH="
for /f "usebackq delims=" %%i in (`"!VSWHERE!" -all -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do call :pick_vs2022 "%%i"
if defined VSPATH goto :have_vs
goto :err_no_vs

rem Sub-batch: only accept an install whose path marks it as VS 2022.
:pick_vs2022
echo %~1 | findstr /C:"Visual Studio\2022" >nul 2>nul
if %errorlevel% gtr 0 exit /b 0
set "VSPATH=%~1"
exit /b 0

:have_vs
echo [vs] VS install (pinned to 2022, nvcc 12.9 rejects newer): !VSPATH!

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

rem --- CUDA toolkit (CUDA mode only; exported by the Jimver/cuda-toolkit step) -
if /I "!MODE_L!"=="cpu" goto :have_tools
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

:have_tools
where cmake
where ninja
if errorlevel 1 goto :err_no_tools

rem --- compose the cmake configure line ---------------------------------------
rem NOTE: WHISPER_BUILD_EXAMPLES must stay ON (its default) -- the whisper-cli
rem executable lives in examples/cli/ (confirmed upstream), so turning examples
rem off deletes the very target we need. The other example executables are NOT
rem wasted work in practice: we build with "--target whisper-cli", so ninja
rem compiles only whisper-cli + its dep closure (common lib, whisper, ggml) --
rem the rest are merely configured, never compiled.
rem What actually gets turned off: tests, server example, SDL2, cURL, NVRTC
rem (not linked by default), OpenMP, native-CPU autotuning (=> exactly ONE
rem baseline ggml-cpu.dll, not the multi-variant matrix), and all warnings
rem noise.
set "CFG_ARGS=-GNinja -DCMAKE_BUILD_TYPE=Release -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_ALL_WARNINGS=OFF -DGGML_CUDA_NCCL=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF -DWHISPER_ALL_WARNINGS=OFF"
if /I "!MODE_L!"=="cpu" (
  set "CFG_ARGS=!CFG_ARGS! -DGGML_CUDA=OFF"
)
if /I "!MODE_L!"=="cuda" (
  set "CFG_ARGS=!CFG_ARGS! -DGGML_CUDA=ON -DGGML_STATIC=ON -DCMAKE_CUDA_ARCHITECTURES=75"
)

echo [cfg] === cmake configure (!MODE_L!) ===
cmake -B !BUILDDIR! -S upstream !CFG_ARGS!
if errorlevel 1 goto :err_cfg
echo [cfg] configure OK

echo [build] === compiling whisper-cli (!MODE_L!) ===
cmake --build !BUILDDIR! --target whisper-cli -j %NUMBER_OF_PROCESSORS%
if errorlevel 1 goto :err_build
echo [build] build OK

echo [out] === !BUILDDIR!\bin contents ===
dir !BUILDDIR!\bin

if exist "!BUILDDIR!\bin\whisper-cli.exe" goto :check_cuda_dll
goto :err_no_cli

:check_cuda_dll
if /I "!MODE_L!"=="cpu" goto :done
if exist "!BUILDDIR!\bin\ggml-cuda.dll" goto :done
goto :err_no_ggml_cuda

:done
echo [build] SUCCESS (!MODE_L!)
exit /b 0

rem ----------------------------------------------------------------- handlers
:err_bad_mode
echo [err] missing or invalid mode argument.
echo       usage: build-whisper-cuda.cmd ^<CUDA^|^CPU^>
exit /b 90

:err_no_vswhere
echo [err] vswhere.exe not found at either:
echo         %ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
echo         %ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe
echo       Fix: install VS 2022 with the "Desktop development with C++" workload.
exit /b 10

:err_no_vs
echo [err] No VS 2022 install with the x64 C++ workload was found.
echo       CUDA 12.9 nvcc only supports VS 2017..2022, so VS 2026 is rejected.
echo       All VS installs on this runner (for diagnosis):
"!VSWHERE!" -all -products * -property installationVersion,installationPath
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
echo       this and export CUDA_PATH. (CPU mode never reaches this handler.)
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
echo [err] cmake and/or ninja are not on PATH. Both are pre-installed on the
echo       GHA windows image; confirm the "Install Ninja" step ran successfully.
exit /b 30

:err_cfg
echo [err] cmake configure failed (!MODE_L!). CMake error output is in the lines
echo       above this (search for "CMake Error" or "CMake Warning").
exit /b 40

:err_build
echo [err] cmake build failed (!MODE_L!). Search the lines above this for
echo       "error C", "fatal error", "error LNK", or "nvcc fatal".
exit /b 41

:err_no_cli
echo [err] build completed but !BUILDDIR!\bin\whisper-cli.exe is absent. CMake
echo       may have placed it elsewhere; grep the build log for whisper-cli.exe.
exit /b 50

:err_no_ggml_cuda
echo [err] build completed but !BUILDDIR!\bin\ggml-cuda.dll is absent - the CUDA
echo       backend did not compile. Defeats the whole reason for the CUDA 12.9
echo       install; see the build log above for the reason.
exit /b 51
