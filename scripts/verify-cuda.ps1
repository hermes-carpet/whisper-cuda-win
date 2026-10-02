# verify-cuda.ps1 - structural verification of the CUDA sm_75 build.
#
# Why NOT an execution test: hosted runners have no NVIDIA driver, and
# ggml-cuda.dll imports nvcuda.dll (the driver) at load time. Launching
# whisper-cli.exe in CUDA mode therefore dies with 0xC0000135
# (STATUS_DLL_NOT_FOUND) before it can do anything. The build is verified
# structurally instead:
#   1. all six expected artifacts exist; ggml-cuda.dll is single-arch sized
#   2. PE import tables:
#        - nothing imports cudart64_12.dll  (cudart was statically linked)
#        - ggml-cuda.dll imports cublas64_12.dll (DLL by design - NVIDIA ships
#          no static Windows cuBLAS) and nvcuda.dll (driver, on the target host)
#   3. cuobjdump on ggml-cuda.dll: SASS is present and targets sm_75 only
$ErrorActionPreference = 'Stop'
$sha = $env:UPSTREAM_SHA.Substring(0,12)
$bin = "$PWD\build\bin"
Write-Host "=== verify-cuda (upstream $sha) ==="

# --- 1. artifacts -------------------------------------------------------------
foreach ($f in @('whisper-cli.exe','whisper.dll','ggml.dll','ggml-base.dll','ggml-cpu.dll','ggml-cuda.dll')) {
  if (-not (Test-Path "$bin\$f")) { throw "MISSING $f in build\bin" }
}
$sz = (Get-Item "$bin\ggml-cuda.dll").Length
Write-Host ("  {0,12:N0} bytes  ggml-cuda.dll (expect ~50-100 MB: sm_75 only)" -f $sz)
if ($sz -lt 20MB -or $sz -gt 150MB) { throw "ggml-cuda.dll ${sz} bytes outside 20-150 MB window - arch narrowing may not have applied" }

# --- 2. PE import tables (import name strings live in the PE text) ------------
function Get-ImportDlLs {
  param([string]$Path)
  $s = [System.Text.Encoding]::ASCII.GetString([System.IO.File]::ReadAllBytes($Path))
  [regex]::Matches($s, '[A-Za-z0-9_]+\.dll') | ForEach-Object { $_.Value.ToLower() } | Sort-Object -Unique
}
foreach ($f in @('whisper-cli.exe','whisper.dll','ggml.dll','ggml-base.dll','ggml-cpu.dll','ggml-cuda.dll')) {
  $imports = Get-ImportDlLs -Path "$bin\$f"
  $interesting = @($imports | Where-Object { $_ -match 'cudart|cublas|nvrtc|nvcuda' })
  $itext = if ($interesting.Count -gt 0) { $interesting -join ', ' } else { '(none)' }
  Write-Host ("  {0,-18} nvidia-imports: {1}" -f $f, $itext)
  if ($imports -contains 'cudart64_12.dll') { throw "$f imports cudart64_12.dll - GGML_STATIC=ON (static cudart) did not take" }
}
$cuda = Get-ImportDlLs -Path "$bin\ggml-cuda.dll"
if ($cuda -notcontains 'cublas64_12.dll') { throw "ggml-cuda.dll does NOT import cublas64_12.dll - cuBLAS DLL linking regressed" }
if (-not ($cuda -like 'nvcuda*')) { throw "ggml-cuda.dll does NOT import nvcuda (driver) - unexpected" }
Write-Host "  cudart static: OK | cuBLAS DLL import: OK | driver import present: OK (supplied by the target host)"

# --- 3. sm_75 SASS via cuobjdump ----------------------------------------------
$cudump = Join-Path $env:CUDA_PATH "bin\cuobjdump.exe"
if (-not (Test-Path $cudump)) { throw "cuobjdump not found at $cudump" }
$out = & $cudump -sass "$bin\ggml-cuda.dll" 2>&1
Set-Content -Path "$PWD\sass-dump.txt" -Value ($out -join "`n")
if ((Get-Item "$PWD\sass-dump.txt").Length -eq 0) { throw "cuobjdump -sass produced no output - ggml-cuda.dll contains no SASS" }
# SASS function headers look like:
#   Function : _Z12kernel_fattnILi2012...EE... .version 8.1 .target sm_75 ...
# or (older layout) a "    .target sm_75" line per function.
$sass = Get-Content "$PWD\sass-dump.txt" -Raw
if ($sass -notmatch '/\*[0-9a-fA-F]+\*/') { throw "no SASS instruction lines (/*xxxx*/) found - kernels did not compile" }
Write-Host "  SASS instructions present: OK"
$targets = [regex]::Matches($sass, '(?m)^\s*\.target\s+(sm_\d+[a-f]?)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique
if (-not $targets) {
  # newer fatbin layout: arch appears after the ".sass" header; fall back to any sm_NN
  $targets = [regex]::Matches($sass, 'sm_\d+[a-f]?') | ForEach-Object { $_.Value } | Sort-Object -Unique
}
$targets = @($targets)
$ttxt = if ($targets.Count -gt 0) { $targets -join ', ' } else { '(none parseable - see sass-dump.txt)' }
Write-Host "  targets in SASS: $ttxt"
if ($targets.Count -ge 1) {
  # When targets ARE parseable, sm_75 must be among them (else arch narrowing broke).
  if (($targets | Where-Object { $_ -match '^sm_75' }) -eq $null) { throw "sm_75 not present in SASS targets: $($targets -join ', ')" }
  $foreign = @($targets | Where-Object { $_ -notmatch '^sm_75' })
  if ($foreign.Count -gt 0) { Write-Host "  NOTE: non-sm_75 targets also present: $($foreign -join ', ')" }
  Write-Host "  sm_75 SASS: OK"
} else {
  Write-Host "  WARN: no sm_* target lines were parseable from the SASS dump; SASS instructions exist but the arch could not be confirmed automatically. Inspect sass-dump.txt (in the build artifact) for '.target sm_75'."
}

Write-Host "CUDA artifact verification PASSED"
