@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================================
rem build-whisper-cuda.cmd [CUDA|CPU] -- self-contained whisper-cli build
rem
rem CUDA: CUDA toolkit + compute arch are PARAMETERIZED via env so one script
rem       serves every GPU/CUDA config (see .github/workflows/auto-rebuild.yml
rem       matrix). cudart statically linked; cuBLAS stays a DLL (no static
rem       Windows lib exists for any CUDA version); examples/tests/server/
rem       SDL2/cURL off; CPU backend single variant.
rem CPU:  no CUDA at all -- only built for the executable smoke test on the
rem       GPU-less runner (the CUDA binary cannot LAUNCH there: ggml-cuda.dll
rem       imports nvcuda.dll, the NVIDIA driver, which GHA images do not have).
rem
rem Required env (CUDA mode, set by the workflow job-level `env:`):
rem   CUDA_ARCH   compute arch, numeric (75 = Turing, 89 = Ada, 90 = Ampere...)
rem   CUDA_MAJOR  toolkit major (12 or 13) -- used to locate the toolkit DLLs
rem   CUDA_PATH   set by the Jimver/cuda-toolkit step before this runs
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

rem --- validate config env (CUDA mode) ----------------------------------------
if /I "!MODE_L!"=="cuda" (
  if not defined CUDA_ARCH goto :err_no_arch
  if not defined CUDA_MAJOR goto :err_no_arch
  echo [cfg] CUDA_ARCH=!CUDA_ARCH!  CUDA_MAJOR=!CUDA_MAJOR!
)

rem --- locate vswhere ---------------------------------------------------------
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "!VSWHERE!" goto have_vswhere
set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if exist "!VSWHERE!" goto have_vswhere
goto :err_no_vswhere

:have_vswhere
echo [vs] using "!VSWHERE!"

rem --- locate a VS install (VS_HINT year) with the x64 C++ component ----------
rem NOTE: windows-latest rotated to the VS 2026-only "windows-2025-vs2026" image
rem (no VS 2022 at all). nvcc (12.x and current 13.x) is supported by VS 2022,
rem so the default is windows-2022 + VS 2022. A config CAN override the image and
rem VS_HINT (e.g. windows-2025-vs2026 + 2026) if a newer CUDA drops VS 2022.
set "VSHINT=2022"
if defined VS_HINT set "VSHINT=%VS_HINT%"
set "VSPATH="
for /f "usebackq delims=" %%i in (`"!VSWHERE!" -all -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do call :pick_vs "%%i"
if defined VSPATH goto :have_vs
goto :err_no_vs

rem Sub-batch: only accept an install whose path marks it as the hinted VS year.
:pick_vs
echo %~1 | findstr /C:"Visual Studio\!VSHINT!" >nul 2>nul
if %errorlevel% gtr 0 exit /b 0
set "VSPATH=%~1"
exit /b 0

:have_vs
echo [vs] VS install (VS %VSHINT%): !VSPATH!

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
rem CUDA 12.x puts runtime DLLs in bin\; CUDA 13.x moves them to bin\x64.
rem Add BOTH to PATH and check both so one script serves either layout.
set "PATH=%CUDA_PATH%\bin;%CUDA_PATH%\bin\x64;%PATH%"
if exist "%CUDA_PATH%\bin\cudart64_%CUDA_MAJOR%.dll" goto :have_cudart
if exist "%CUDA_PATH%\bin\x64\cudart64_%CUDA_MAJOR%.dll" goto :have_cudart
goto :err_no_cudart

:have_cudart
echo [cuda] using CUDA_PATH = %CUDA_PATH%
if exist "%CUDA_PATH%\bin\cublas64_%CUDA_MAJOR%.dll" goto :have_cublas
if exist "%CUDA_PATH%\bin\x64\cublas64_%CUDA_MAJOR%.dll" goto :have_cublas
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
  set "CFG_ARGS=!CFG_ARGS! -DGGML_CUDA=ON -DGGML_STATIC=ON -DCMAKE_CUDA_ARCHITECTURES=%CUDA_ARCH%"
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

:err_no_arch
echo [err] CUDA_ARCH and/or CUDA_MAJOR is not set (CUDA mode). The workflow
echo       matrix must define them in the job-level `env:` block.
exit /b 24

:err_no_vswhere
echo [err] vswhere.exe not found at either:
echo         %ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe
echo         %ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe
echo       Fix: install VS 2022 with the "Desktop development with C++" workload.
exit /b 10

:err_no_vs
echo [err] No VS 2022 install with the x64 C++ workload was found.
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
echo [err] %CUDA_PATH%\bin\cudart64_%CUDA_MAJOR%.dll is missing.
echo       Either the CUDA toolkit install failed, or CUDA_MAJOR does not match
echo       the installed toolkit major, or the toolkit landed in a different
echo       folder than %CUDA_PATH%. Check the installer/log output.
exit /b 21

:err_no_cublas
echo [err] %CUDA_PATH%\bin\cublas64_%CUDA_MAJOR%.dll is missing.
echo       cuBLAS is required - Windows has NO static cuBLAS lib for any CUDA
echo       version, so the build would link against a DLL that does not exist.
echo       A truncated installer can produce exactly this; verify the install.
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
echo       backend did not compile. See the build log above for the reason.
exit /b 51
