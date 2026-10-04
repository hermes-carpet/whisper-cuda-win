# CI — CUDA 13.x on GitHub Actions (Windows): findings & the 13.3 switch

Status: 2060/Turing (sm_75) ships on **CUDA 12.9 via Jimver** — **green, proven.**
4060/Ada (sm_89) was on **CUDA 13.4 via winget** — **broken**, now switching to **13.3.1 via Jimver**.

This file is the durable record of what we tried, what worked, and what "12.9 does"
(reference recipe, since 12.9 stays on GitHub and always works).

---

## TL;DR — what works and why

| Lane | Arch | CUDA | Method | Status |
|------|------|------|--------|--------|
| `turing-cuda12.9` | sm_75 | 12.9.0 | `Jimver/cuda-toolkit` `method:network` | ✅ GREEN — the reference |
| `ada-cuda13.4` (old) | sm_89 | 13.4 | winget `Nvidia.CUDA` + manual download fallback | ❌ BROKEN |
| `ada-cuda13.3` (new) | sm_89 | 13.3.1 | `Jimver/cuda-toolkit` `method:network` | ← target, same route as 12.9 |

**The fix:** point the 4060 lane at **13.3.1 via Jimver** instead of 13.4 via winget.
This is *exactly* the route the working 12.9 lane uses — no winget Appx bootstrap,
no `Add-AppxPackage`, no manual `Invoke-WebRequest` installer download, no 3.6 GB local.

---

## Why 13.4 broke (root cause, verified from real logs)

It was **not** a compile or link failure. The build step was never run — the run
died in the **install gate**:

1. The Windows CUDA **13.4** silent install (`-s`) installs the whole **build** surface:
   `nvcc.exe`, `cuobjdump.exe`, `lib\x64\cublas.lib`, `lib\x64\cudart_static.lib`,
   `include\cublas_api.h`. **All present** (confirmed by probe, install exit 0).
2. But it does **NOT** place the cuBLAS **runtime** `bin\cublas64_13.dll`. In the 13.x
   Windows installer, the cuBLAS **runtime** DLL landed in a separate **sub-package**
   (`cublas_13.4`), not in the compiler-core default set.
3. `auto-rebuild.yml`'s `Get-ToolkitDir` gate (line ~361) requires
   `bin\nvcc.exe` **AND** `bin\cublas64_$major.dll`. The DLL is missing → gate fails →
   "CUDA 13.4 install failed" → build step **skipped** → whole job red.

Probe VERDICT (13.4, `-s`, single clean invocation):
```
VERDICT variant=S-baseline-s: nvcc=True cuobjdump=True cublas_dl=False
                               cublas_lib=True cudart_static=True cublas_hdr=True
```
Only `cublas_dl=False` — the runtime DLL. Everything a build needs *except* the DLL
that the packaging `portable` variant bundles and the gate checks.

Secondary 13.4 pain (winget path, real log):
- Runner had **no winget**; bootstrap failed:
  `Add-AppxPackage : Deployment failed with HRESULT: 0x80073CF3` → "winget unavailable".
- Fell through to the **manual `Invoke-WebRequest` installer** download+run — the
  "actions manually download the installer" path the user doesn't want.
- That direct 13.4.1 local install exited 0 but still failed the `Get-ToolkitDir` gate.

### The 13.4 bootstrapper gotcha (probe round 2)
If the 13.4 bootstrapper is run **twice on the same runner** (e.g. a `-h`/usage dump
then a real install), the second call dies with exit code **`-469762040`** and installs
*nothing*. On `windows-2022`, run the 13.4 bootstrapper **exactly once** per machine.

---

## Why 13.3 (and why it should just work)

- **Minor-version compat:** a 13.3-built `whisper-cli` runs on a CUDA 13.4 host.
  Same major (13), no runtime mismatch. User: ".3 → .4 has no advantages for STT."
- **Same proven route as 12.9:** 13.3.1 is in **Jimver's** Windows CDN map (verified in
  `Jimver/cuda-toolkit` → `src/links/windows-links.ts`, updated Aug 2026):
  - `'13.3.1'` → `…/13.3.1/network_installers/cuda_13.3.1_windows_network.exe` (~10 MB stub)
  - `'13.3.0'` → `…/13.3.0/network_installers/cuda_13.3.0_windows_network.exe`
  So `Jimver/cuda-toolkit` with `cuda: 13.3.1, method: network` behaves like the 12.9
  lane — **no winget, no manual download.**
- **Runtime DLL in `bin\`:** the cuBLAS runtime-as-separate-subpackage split is a
  **13.4-era change**; 13.3 (like 12.9) is expected to put `cublas64_13.dll` in `bin\`,
  satisfying the existing `Get-ToolkitDir` gate unchanged. *(To be confirmed by the
  `cuda13-probe` job — it installs via Jimver 13.3.1 and both dumps the build surface
  AND recursively locates `cublas64_13.dll` anywhere under the CUDA root.)*

> If the 13.3 probe shows the runtime is NOT in `bin\` (i.e. the sub-package split
> backported to 13.3), the only change needed is to the install gate / the `portable`
> packaging: pull the cuBLAS sub-package or relax `Get-ToolkitDir` to a known-good
> runtime path. Do **not** hardcode NVIDIA URLs in the workflow (they go stale and
> break the run) — keep every install route manifest/CDN-driven.

---

## Reference: the WORKING 12.9 recipe (keep this as the template)

From `.github/workflows/auto-rebuild.yml`, matrix entry `turing-cuda12.9` → **green**:

```
- cfg: turing-cuda12.9
  install_method: jimver
  arch: 75
  build_cuda: '12.9.0'      # CUDA toolkit version CI installs
  dll_major: '12'           # cublas64_12.dll / cudart64_12.dll
  host_cuda: '12.9'         # zip suffix + host env major.minor
  host_env_var: 'CUDA_PATH_V12_9'
  gpu: 'RTX 2060 / 2070 / 2080 / Titan Xp (Turing sm_75)'
  arch_short: 'Turing sm_75'
```

Install step (Jimver — this is the route 13.3 now uses too):
```yaml
- name: Install CUDA ${{ matrix.build_cuda }} via Jimver (config ${{ matrix.cfg }})
  if: matrix.install_method == 'jimver'
  uses: Jimver/cuda-toolkit@v0.2.36
  with:
    cuda: '12.9.0'
    method: 'network'
```

`Get-ToolkitDir` gate this config satisfies (12.9 puts the runtime in `bin\`):
```powershell
function Get-ToolkitDir {
  $d = Join-Path $cudaRoot "v$ver"     # v12.9
  if ((Test-Path (Join-Path $d "bin\nvcc.exe")) -and
      (Test-Path (Join-Path $d "bin\cublas64_$major.dll"))) { return $d } else { return $null }
}
```

---

## The 13.3 config (this change)

`auto-rebuild.yml`, replace the `ada-cuda13.4` matrix entry and drop the winget path:

```
- cfg: ada-cuda13.3
  install_method: jimver
  arch: 89
  build_cuda: '13.3.1'      # 13.3 line, newest patch in Jimver's map
  dll_major: '13'           # cublas64_13.dll / cudart64_13.dll
  host_cuda: '13.3'         # zip suffix + host env major.minor
  host_env_var: 'CUDA_PATH_V13_3'
  gpu: 'RTX 4060 (Ada sm_89)'
  arch_short: 'Ada sm_89'
```

> **Host env var caveat:** switching 13.4 → 13.3 changes the host env var from
> `CUDA_PATH_V13_4` to `CUDA_PATH_V13_3`. If the desktop launcher/installer is
> hardcoded to `CUDA_PATH_V13_4`, decide:
>   (a) keep `host_env_var: 'CUDA_PATH_V13_4'` so existing 13.4 installs keep working
>       if the runtime is compatible, or
>   (b) bump the launcher to `CUDA_PATH_V13_3`.
> Confirm against the launcher/install.ts before shipping. A 13.3-built binary runs
> under a 13.3 or any-13.x toolkit; the env var just tells it where to find cuBLAS.

Release naming stays per the standing convention: `whisper-cli-<v>-win-cuda<host>.zip`
(slim) and `…-win-cuda<host>-cublas.zip` (portable), tag `whisper-<v>`, title
`whisper-cli <v>` (no CUDA line in the title/note).

---

## Verified external facts (not guesses)

- **Jimver/cuda-toolkit** `src/links/windows-links.ts`: `13.3.1`, `13.3.0`, `13.2.x`,
  `13.1.x`, `13.0.x`, `12.9.x` all present with network + local URLs. (commit b8bf9c6, Aug 2026)
- **NVIDIA network stubs:** `cuda_13.3.1_windows_network.exe` = **10 MB** (200 OK),
  `cuda_13.3.1_windows.exe` = **2.45 GB** local. → use the `_network.exe` via Jimver.
- **winget-pkgs `Nvidia.CUDA`:** line 13.3 exists (`Nvidia.CUDA.installer.yaml`,
  silent `-y -gm2 -s -n`, → `cuda_13.3.1_windows.exe` local). Line 13.4 exists too
  (→ `cuda_13.4.1_windows_x86_64.exe`). Winget is a valid route but needs the Appx
  bootstrap on hosted runners (the 0x80073CF3 path) — Jimver avoids that.

## Files that changed for this switch
- `.github/workflows/auto-rebuild.yml` — ada lane → `ada-cuda13.3`, `install_method: jimver`
- `.github/workflows/cuda13-probe.yml` — now a 13.3.1-Jimver build-surface + runtime-locate probe
- `CI-CUDA-13-finding-notes.md` — this file
