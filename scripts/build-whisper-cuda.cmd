@echo off
setlocal EnableExtensions EnableDelayedExpansion

rem ============================================================================
rem build-whisper-cuda.cmd
rem
rem Self-contained Windows build for the slim CUDA 12.9 / sm_75 (Turing)
rem whisper-cli package. Called from .github/workflows/auto-rebuild.yml.
rem
rem Design:
rem   * Discover Visual Studio via vswhere (no hardcoded 2022 Enterprise path).
rem   * `call vcvarsall.bat x64` inside this SINGLE batch so its env
rem     (cl / link / INCLUDE / LIB / PATH) is available to cmake + ninja +
rem     nvcc below. vcvars does NOT persist to a sibling .cmd step.
rem   * Add the CUDA toolkit's bin (from $CUDA_PATH, which Jimver/cuda-toolkit
rem     exports) to PATH so nvcc + the CUDA libraries resolve.
rem   * Configure then build with --target whisper-cli (only the CLI + the
rem     DLL closure whisper.dll, ggml.dll, ggml-base.dll, ggml-cpu.dll,
rem     ggml-cuda.dll are produced).
rem
rem Fails with a distinct non-zero exit code for each stage so the workflow
rem log shows exactly which stage broke.
rem ============================================================================

echo [build] === toolchain discovery ===

rem --- locate vswhere (2022/2019; the x64-ProgramFiles tree is where the installer lives) ---
set "VSWHERE=%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "!VSWHERE!" set "VSWHERE=%ProgramFiles%\Microsoft Visual Studio\Installer\vswhere.exe"
if not exist "!VSWHERE!" (
  echo [vs] ERROR: vswhere.exe not found at either ^
  echo            %%ProgramFiles(x86)%% or %%ProgramFiles%% /Microsoft Visual Studio/Installer.
  echo                  Windows 2022+ runners install it at the (x86) path by default.
  exit /b 10
)
echo [vs] using vswhere "!VSWHERE!"

set "VSPATH="
for /f "usebackq delims=" %%i in (`"!VSWHERE!" -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath`) do set "VSPATH=%%i"

if "%VSPATH%"=="" (
  echo [vs] ERROR: vswhere found no Visual Studio install with the x64 C++ workload.
  echo            Try: "!VSWHERE!" -all -format json   ^<- run that manually to enumerate installs.
  exit /b 11
)
echo [vs] VS install: !VSPATH!

set "VCVARS=!VSPATH!\VC\Auxiliary\Build\vcvarsall.bat"
if not exist "!VCVARS!" (
  echo [vs] ERROR: vcvarsall.bat not found under !VSPATH!.
  exit /b 12
)

call "!VCVARS!" x64
if errorlevel 1 (echo [vs] ERROR: vcvarsall.bat x64 failed; see above. & exit /b 13)

if not defined INCLUDE (echo [vs] ERROR: INCLUDE env not set after vcvarsall -- something odd. & exit /b 14)
echo [vs] vcvarsall OK. cl =
call where cl

rem --- make CUDA toolkit visible (Jimver exports CUDA_PATH; add its bin for nvcc + libs) ---
if "%CUDA_PATH%"=="" (
  echo [cuda] ERROR: CUDA_PATH is not set.
  echo            The Jimver/cuda-toolkit step must run BEFORE this script and successfully
  echo            install the requested toolkit; re-check that step's log.
  exit /b 20
)
set "PATH=%CUDA_PATH%\bin;%PATH%"
if exist "%CUDA_PATH_V12_9%\bin\cudart64_12.dll" (echo [cuda] CUDA 12.9 toolkit: %CUDA_PATH_V12_9%  & set "CUDA_PATH=%CUDA_PATH_V12_9%")
echo [cuda] Using CUDA_PATH = %CUDA_PATH%
if not exist "%CUDA_PATH%\bin\cudart64_12.dll" (
  echo [cuda] ERROR: %CUDA_PATH%\bin\cudart64_12.dll missing.
  echo            Expected after a normal CUDA 12.9 install. The Jimver step may have
  echo            installed under a different folder; see the "dir CUDA_PATH\bin" output
  echo            above (or in the workflow log).
  exit /b 21
)
if not exist "%CUDA_PATH%\bin\cublas64_12.dll" (
  echo [cuda] ERROR: %CUDA_PATH%\bin\cublas64_12.dll missing.
  echo            cuBLAS is a hard requirement for the slim build (no static lib on Win).
  exit /b 22
)

rem --- show toolchain sanity ---
call nvcc --version
if errorlevel 1 (echo [cuda] nvcc not on PATH -- check CUDA_PATH\bin in the log above. & exit /b 23)
echo [cuda] nvcc OK.
where cmake
where ninja
if errorlevel 1 (
  echo [tool] cmake or ninja not on PATH -- confirm the Install Ninja step ran.
  exit /b 30
)

echo [tool] toolchain OK, starting CMake configure for sm_75 / CUDA 12.9.

cmake -B build -S upstream -G "Ninja" -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_CUDA_ARCHITECTURES=75 -DGGML_CUDA=ON -DGGML_STATIC=ON ^
  -DGGML_NATIVE=OFF -DGGML_OPENMP=OFF -DGGML_ALL_WARNINGS=OFF ^
  -DGGML_CUDA_NCCL=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF ^
  -DWHISPER_SDL2=OFF -DWHISPER_CURL=OFF -DWHISPER_ALL_WARNINGS=OFF \
  || (echo [cfg] ERROR: cmake configure failed. & exit /b 40)
echo [cfg] configure OK.

echo [build] === compiling whisper-cli ---
cmake --build build --target whisper-cli -j %NUMBER_OF_PROCESSORS% \
  || (echo [build] ERROR: cmake build failed. & exit /b 41)
echo [build] build OK.

echo [out] === build/bin contents ===
dir build\bin

if not exist "build\bin\whisper-cli.exe" (echo [out] ERROR: whisper-cli.exe missing after build. & exit /b 50)
if not exist "build\bin\ggml-cuda.dll"   (echo [out] ERROR: ggml-cuda.dll missing -- CUDA backend did not build. & exit /b 51)

echo [build] SUCCESS.
exit /b 0
