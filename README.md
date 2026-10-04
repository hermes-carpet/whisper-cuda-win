# whisper-cuda-win

Auto-built **`whisper-cli` for Windows 10 + NVIDIA GPUs** — one zip per GPU class,
built on CUDA and packaged on GitHub Actions, nothing to install here.

Two configs per release:

| Config | GPU | Arch | CUDA |
|--------|-----|------|------|
| `turing-cuda12.9` | RTX 2060 / 2070 / 2080 / Titan Xp | sm_75 | 12.9 |
| `ada-cuda13.3` | RTX 4060 | sm_89 | 13.3 |

Mirrors the `hermes-carpet/llama-slim` pattern: a **weekly cron** (Tue 09:00 UTC)
polls `ggml-org/whisper.cpp` master. When a new upstream commit appears and the build
**passes a CPU smoke test** on the no-GPU runner, it publishes a GitHub Release
containing every config's two zips and **self-commits** the published SHA back to
this repo. That self-commit keeps the pipeline fresh (no GitHub inactivity timeout)
and is the next poll's "already done" marker. A failed build or test publishes
nothing — the last passing release stays.

Each release is named after the **upstream version** parsed from whisper.cpp's
`CMakeLists.txt` (e.g. **1.9.4**). If the commit is exactly the upstream `vX.Y.Z`
tag, the version is clean; if it's a master commit between tags (a dev build), a
`-dev` suffix is added (e.g. `1.9.4-dev`) so the number isn't mistaken for the
tagged release. The full upstream SHA is always recorded in the release notes.

- Release **tag**: `whisper-<version>` (e.g. `whisper-1.9.4-dev`)
- Release **title**: `whisper-cli <version>`
- **Assets** (two zips per config):
  - `whisper-cli-<version>-win-cuda12.9.zip` (slim) / `...-cuda12.9-cublas.zip` (2060)
  - `whisper-cli-<version>-win-cuda13.3.zip` (slim) / `...-cuda13.3-cublas.zip` (4060)

If the version ever can't be resolved (upstream layout change), naming falls back
to the 12-char SHA with a CI warning — the build still publishes.

Grab the latest build from **Releases** → the `cuda12.9` zip if you have a 20-series
Turing card, the `cuda13.3` zip if you have an RTX 4060 (Ada).

## What's in it

| File | What it is |
|------|-----------|
| `whisper-cli.exe` | the CLI |
| `ggml-cuda.dll` | CUDA backend, single-arch (sm_75 for Turing, sm_89 for Ada) |
| `ggml.dll`, `ggml-base.dll`, `ggml-cpu.dll`, `whisper.dll` | the rest of the runtime closure |
| `whisper.bat` | launcher: resolves the CUDA toolkit via `CUDA_PATH_V12_9` (2060) or `CUDA_PATH_V13_3` (4060) |
| `cublas*.dll` | **`-cublas` zips only** — the cuBLAS runtime, bundled for machines without a CUDA toolkit |

`whisper.bat` puts the toolkit's `bin` (and `bin\x64`, where CUDA **13.x** keeps the
runtime DLLs; 12.x uses plain `bin`) **first** on `PATH` before launching, so
cuBLAS/cuDART load from your matching CUDA install rather than whatever is on a
polluted `PATH`. If the env var is unset it prints the exact fix instead of failing
silently. The slim zip needs the matching major CUDA toolkit (12.9 or 13.x); the
`-cublas.zip` works on a machine with no CUDA toolkit at all (just the GPU driver).

## Why these build flags

| Flag | Effect |
|------|--------|
| `-DCMAKE_CUDA_ARCHITECTURES=75` / `89` | single-arch per config. Biggest size cut — `ggml-cuda.dll` goes from ~545 MB (multi-arch) to tens of MB. |
| `-DGGML_STATIC=ON` | cudart is **statically linked**, so `cudart64_*.dll` is not needed at runtime. |
| cuBLAS stays a DLL | NVIDIA ships **no** static `cublas.lib` for Windows (see upstream `ggml/src/ggml-cuda/CMakeLists.txt`: *"CUDA Toolkit for Windows does not offer a static cublas library"*). `ggml-cuda.dll` links `cudart_static` + dynamic `cublas`. |
| `-DGGML_NATIVE=OFF` `-DGGML_OPENMP=OFF` | one baseline CPU backend (the multi-variant matrix is off). |
| `-DWHISPER_BUILD_TESTS=OFF` `-DWHISPER_BUILD_SERVER=OFF` `-DWHISPER_SDL2=OFF` | examples, tests, server and SDL2 are off. |
| `--target whisper-cli` | only the CLI + its dependency closure compiles; nothing else. |

Kernels are nvcc-compiled to single-arch SASS at build time (no runtime JIT/NVRTC):
instant cold start, and the binary is tied to its CUDA build.

## Host requirements

**2060 box (slim cuda12.9 zip):**
- Windows 10 x64, NVIDIA GPU driver installed (provides `nvcuda.dll`).
- CUDA **12.9** toolkit installed, so `CUDA_PATH_V12_9` points at it (the toolkit
  sets this automatically; it exists specifically so apps can find the 12.9 runtime).

**4060 box (slim cuda13.3 zip):**
- Windows 10 x64, NVIDIA GPU driver installed.
- Any CUDA **13.x** toolkit installed (13.3+), so `CUDA_PATH_V13_3` points at it.
  A 13.3-built binary runs on any 13.x host toolkit.

**Both:** the model (e.g. `ggml-large-v3-turbo.bin`) sits separately — it is
**not** bundled in the zip. With a `-cublas` zip the only requirement is the driver
(no toolkit needed).

## Usage

```bat
cd c:\path\to\release
whisper.bat -m your-model.bin -f audio.wav -l en
```

Or call `whisper-cli.exe` directly if you already have the matching CUDA toolkit
`bin` on `PATH`.

## CI / auto-updates

`.github/workflows/auto-rebuild.yml`:

- **Weekly** (`schedule`): Tuesday 09:00 UTC — polls `ggml-org/whisper.cpp` master.
- **`workflow_dispatch`** — manual; pass `upstream_sha` (optional) and `force`
  to rebuild a specific/published SHA.

On a new SHA it: (1) shallow-fetches upstream at that SHA (ggml is vendored, no
submodules), (2) installs CUDA per config via `Jimver/cuda-toolkit`
(`method: network` — 12.9.0 for Turing, 13.3.1 for Ada; the action resolves the
installer from its own CDN map, so no hardcoded NVIDIA URL can go stale, and it
avoids the winget Appx-bootstrap path that hosted runners break on), (3) configures
+ builds `--target whisper-cli` per config, (4) structurally verifies every CUDA
artifact (static cudart, cuBLAS import, single-arch SASS via cuobjdump) and runs
the **CPU smoke test** once (`ggml-tiny.en.bin` on `samples/jfk.wav` — the runner
has no GPU, so this exercises the CPU fallback path and confirms the DLL closure
actually loads), (5) only on full pass, packages every config's two zips and
publishes ONE release.

Adding a third GPU/CUDA class is one row in the `build-windows` matrix — naming,
launcher env var, zip suffix and release notes are all derived from that row.

## CI history note

Why 13.3 and not 13.4 for the Ada build, and why all installs go through
Jimver: `CI-CUDA-13-finding-notes.md` documents the 13.4/winget failure, the root
cause (CUDA 13.x installs runtime DLLs in `bin\x64\`, not `bin\`), the fix, and
the 12.9 reference recipe.
