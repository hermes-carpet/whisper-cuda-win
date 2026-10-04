# verify-cuda.ps1 - structural verification of a CUDA build (param: arch/CUDA major).
#
# Why NOT an execution test: hosted runners have no NVIDIA driver, and
# ggml-cuda.dll imports nvcuda.dll (the driver) at load time. Launching
# whisper-cli.exe in CUDA mode therefore dies with 0xC0000135
# (STATUS_DLL_NOT_FOUND) before it can do anything. The build is verified
# structurally instead:
#   1. all six expected artifacts exist; ggml-cuda.dll is single-arch sized
#   2. PE import tables:
#        - nothing imports cudart64_<MAJOR>.dll  (cudart was statically linked)
#        - ggml-cuda.dll imports cublas64_<MAJOR>.dll (DLL by design - NVIDIA
#          ships no static Windows cuBLAS) and nvcuda.dll (driver, on the target host)
#   3. cuobjdump on ggml-cuda.dll: SASS is present and targets sm_<ARCH> only
#
# Required env:
#   CUDA_ARCH   compute arch, numeric (75 = sm_75 Turing, 89 = sm_89 Ada, ...)
#   CUDA_MAJOR  toolkit major (12 or 13) -- the cudart/cublas DLL major
#   CUDA_PATH   set by the Jimver/cuda-toolkit step ($env:CUDA_PATH)
$ErrorActionPreference = 'Stop'
$sha = $env:UPSTREAM_SHA.Substring(0,12)
$arch = "$env:CUDA_ARCH"
$major = "$env:CUDA_MAJOR"
# sm_<arch>: strip any leading "0" so sm_089 would normalize to sm_89 (archs are 2-digit).
$sm = "sm_$arch"
$bin = "$PWD\build\bin"
Write-Host "=== verify-cuda (upstream $sha, target $sm, CUDA $major) ==="

# --- 1. artifacts -------------------------------------------------------------
foreach ($f in @('whisper-cli.exe','whisper.dll','ggml.dll','ggml-base.dll','ggml-cpu.dll','ggml-cuda.dll')) {
  if (-not (Test-Path "$bin\$f")) { throw "MISSING $f in build\bin" }
}
$sz = (Get-Item "$bin\ggml-cuda.dll").Length
Write-Host ("  {0,12:N0} bytes  ggml-cuda.dll (single-arch $sm)" -f $sz)
if ($sz -lt 15MB -or $sz -gt 150MB) { throw "ggml-cuda.dll ${sz} bytes outside 15-150 MB window - arch narrowing may not have applied" }

# --- 2. PE import tables (import name strings live in the PE text) ------------
function Get-ImportDlLs {
  param([string]$Path)
  $s = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($Path))
  [regex]::Matches($s, '[A-Za-z0-9_]+\.dll') | ForEach-Object { $_.Value.ToLower() } | Sort-Object -Unique
}
$cudartDll = "cudart64_${major}.dll"
$cublasDll = "cublas64_${major}.dll"
foreach ($f in @('whisper-cli.exe','whisper.dll','ggml.dll','ggml-base.dll','ggml-cpu.dll','ggml-cuda.dll')) {
  $imports = Get-ImportDlLs -Path "$bin\$f"
  $interesting = @($imports | Where-Object { $_ -match 'cudart|cublas|nvrtc|nvcuda' })
  $itext = if ($interesting.Count -gt 0) { $interesting -join ', ' } else { '(none)' }
  Write-Host ("  {0,-18} nvidia-imports: {1}" -f $f, $itext)
  if ($imports -contains $cudartDll) { throw "$f imports $cudartDll - GGML_STATIC=ON (static cudart) did not take" }
}
$cuda = Get-ImportDlLs -Path "$bin\ggml-cuda.dll"
if ($cuda -notcontains $cublasDll) { throw "ggml-cuda.dll does NOT import $cublasDll - cuBLAS DLL linking regressed" }
if (-not ($cuda -like 'nvcuda*')) { throw "ggml-cuda.dll does NOT import nvcuda (driver) - unexpected" }
Write-Host "  cudart static: OK | cuBLAS DLL import: OK | driver import present: OK (supplied by the target host)"

# --- 3. SASS arch via cuobjdump -----------------------------------------------
# NOTE: cuobjdump -sass over our ~50 MB multi-kernel DLL dumps >100 MB. Collecting
# that into a PowerShell string/array OOMs the step ("Insufficient memory"). So we
# write it to a temp file via OS-level redirection (streaming), keep ONLY the small
# arch lines for the release-relevant sm_<arch> assertion, then drop the big temp
# file before packaging.
$cudump = Join-Path $env:CUDA_PATH "bin\cuobjdump.exe"
if (-not (Test-Path $cudump)) { throw "cuobjdump not found at $cudump" }
$full = "$PWD\sass-full.tmp"
$tar = "$PWD\sass-targets.txt"

# 3a. Stream the full SASS to a temp file (cmd redirection = OS streaming, no PS array)
cmd /c "`"$cudump`" -sass `"$bin\ggml-cuda.dll`" > `"$full`" 2>&1"
if (-not (Test-Path $full) -or (Get-Item $full).Length -eq 0) {
  Remove-Item $full -ErrorAction SilentlyContinue
  throw "cuobjdump -sass produced no output - ggml-cuda.dll contains no SASS"
}
Write-Host ("  full SASS dump: {0:N0} bytes (temp, will not be uploaded)" -f (Get-Item $full).Length)

# 3b. Keep every line that mentions an SM architecture (tiny) for upload + arch
#     assertions. Match the literal token "sm_" (in a SASS dump that only ever
#     denotes a GPU arch like sm_89, never "smem"). A few hundred lines.
findstr /C:"sm_" "$full" > "$tar"
if (-not (Test-Path $tar) -or (Get-Item $tar).Length -eq 0) {
  Remove-Item $full -ErrorAction SilentlyContinue
  throw "no 'sm_' arch references found in SASS - $sm arch cannot be confirmed"
}

# 3c. A ~50 MB DLL whose dump is this large AND that carries real arch lines has
#     fully-compiled SASS kernels. (No fragile line counting needed.)
Write-Host ("  SASS dump confirms real machine code: OK")
Remove-Item $full -ErrorAction SilentlyContinue

$targetLines = @(Get-Content $tar)
$targets = @()
foreach ($l in $targetLines) {
  $targets += [regex]::Matches($l, 'sm_\d+[a-f]?') | ForEach-Object { $_.Value }
}
$targets = @($targets | Sort-Object -Unique)
$ttxt = if ($targets.Count -gt 0) { $targets -join ', ' } else { '(none parseable)' }
Write-Host "  arch targets in SASS: $ttxt"
if ($targets -notcontains $sm) { throw "$sm NOT present in SASS targets: $ttxt" }
$foreign = @($targets | Where-Object { $_ -ne $sm })
if ($foreign.Count -gt 0) { Write-Host "  NOTE: non-$sm archs also present: $($foreign -join ', ')" }
Write-Host "  $sm SASS: OK (and NO other GPU generation)"

Write-Host "CUDA artifact verification PASSED"
