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

## Why the 13.4 (and would-be 13.3) build broke — root cause, corrected & verified

**Corrected diagnosis (probe round on 13.3.1, the shipping route):** the CUDA 13.x
Windows installer does **not** keep the runtime DLLs in `bin\` where 12.x put them —
**13.x installs them in `bin\x64\`**. Everything else stayed put, which is why the
failure was silent and confusing:

| Artifact | 12.9 location | 13.x location (verified) |
|----------|---------------|---------------------------|
| `nvcc.exe`, `cuobjdump.exe`, … | `bin\` | `bin\` (unchanged) |
| `cublas.lib`, `cudart_static.lib`, … | `lib\x64\` | `lib\x64\` (unchanged) |
| `cublas_api.h`, … | `include\` | `include\` (unchanged) |
| **`cublas64_<N>.dll`, `cudart64_<N>.dll`** | `bin\` | **`bin\x64\`** ← moved |

(An earlier theory — "cuBLAS moved to a sub-package that must be opted into" — was
**wrong**: the 13.3.1 probe found the full 52 MB `cublas64_13.dll` and
`cudart64_13.dll` installed, just under `bin\x64\`.)

The build itself *links* against `lib\x64\cublas.lib` + `cudart_static.lib` (present
on both), so compilation succeeds. What broke was every `bin\cublas64_13.dll` /
`bin\cudart64_13.dll` check:
1. `auto-rebuild.yml`'s install gate (`Get-ToolkitDir` required `bin\cublas64_$major.dll`)
2. `scripts\build-whisper-cuda.cmd`'s `:have_cudart` / `:have_cublas` existence gates
3. the portable `-cublas` packaging step (gathered `cublas*.dll` from `bin\` → would
   bundle **nothing** on 13.x)
4. the `whisper.bat` host launcher (puts `%CUDA_PATH_Vx_x%\bin` first on PATH → wrong
   folder on any 13.x host, including the desktop)

### The fix (version-independent, committed `0214af4`)
Every `bin\` reference now also covers `bin\x64\` (12.x and 13.x both work with one
script / one launcher). Verified green: run `37181584176` (force) → both legs
(`turing-cuda12.9` AND `ada-cuda13.3` at 13.3.1) `completed success`, CPU smoke
success.

Why 13.3.1 via Jimver (not 13.4 via winget) for the Ada lane:
- **Same proven route as 12.9** — `Jimver/cuda-toolkit` `method: network`; Jimver's
  CDN map resolves 13.3.1 (verified in `src/links/windows-links.ts`, updated Aug 2026).
  No winget Appx bootstrap (that 404/0x80073CF3 mess), no manual installer download,
  no hardcoded NVIDIA URL.
- **13.4 is not in Jimver's map**, so it would have needed the winget/bootstrap path
  anyway.
- 13.3-built binary runs on a 13.x host (same major); ".3 -> .4 has no advantages
  for STT."

Secondary 13.4 pain (winget path, real log, for reference):
- Runner had **no winget**; bootstrap failed:
  `Add-AppxPackage : Deployment failed with HRESULT: 0x80073CF3` → "winget unavailable".
- Fell through to the **manual `Invoke-WebRequest` installer** download+run — the
  "actions manually download the installer" path the user doesn't want.

### The 13.4 bootstrapper gotcha (probe round 2)
If the 13.4 bootstrapper is run **twice on the same runner** (e.g. a `-h`/usage dump
then a real install), the second call dies with exit code **`-469762040`** and installs
*nothing*. On `windows-2022`, run a 13.4 bootstrapper invocation **exactly once** per
machine. (Moot now that 13.4 is out of the picture, but it bit three probe rounds.)

### Release-publish gotcha (bit run `37181584176`, fixed in `09d2458`)
The release step's idempotency was `gh api -X DELETE … || true`. A transient API
failure left the stale `whisper-1.9.4-dev` tag in place and the POST 422'd with
`tag_name already_exists`. Fixed: retry-verify loop (GET → DELETE → GET-404, 5
attempts, hard-fail). Note for future deletes: `DELETE /releases/{id}` returns **204
with an empty body** — any `-q` jq post-filter makes the call "fail" (jq gets EOF);
check the HTTP code, not the body.

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
