# whisper-cuda-win

Auto-built **`whisper-cli` for Windows 10 + NVIDIA GTX/RTX 2060 (Turing, sm_75)**,
tuned for CUDA 12.9. Built entirely on GitHub Actions — nothing to install here.

Mirrors the `hermes-carpet/llama-slim` pattern: a **weekly cron** (Tue 09:00 UTC)
polls `ggml-org/whisper.cpp` master. When a new upstream commit appears and the build
**passes a CPU smoke test** on the no-GPU runner, it publishes a GitHub Release
and **self-commits** the published SHA back to this repo. That self-commit keeps
the pipeline fresh (no GitHub inactivity timeout) and is the next poll's "already
done" marker. A failed build or test publishes nothing — the last passing release
stays.

Each release is named **`whisper-v<version>`** where the version is parsed from
upstream `CMakeLists.txt` (e.g. `v1.9.4`). If the commit is between upstream tags
(a dev build), the tag/notes read **`v<version>-dev`** so the number isn't mistaken
for the tagged release. Asset *filenames* use the 12-char SHA — unchanged since
the build step names the zips before the release step resolves the label.

Grab the latest build from **Releases** → `whisper-cli-win-cuda12.9-<sha>.zip`.

## What's in it

| File | What it is |
|------|-----------|
| `whisper-cli.exe` | the CLI |
| `ggml-cuda.dll` | CUDA backend, ~60-100 MB (single-arch sm_75 cut) |
| `ggml.dll`, `ggml-base.dll`, `ggml-cpu.dll`, `whisper.dll` | the rest of the runtime closure |
| `whisper.bat` | launcher: resolves CUDA 12.9 via `CUDA_PATH_V12_9` |

`whisper.bat` puts `%CUDA_PATH_V12_9%\bin` **first** on `PATH` before launching,
so cuBLAS/cuDART load from your CUDA 12.9 install rather than whatever is on a
polluted `PATH`. If `CUDA_PATH_V12_9` is unset it prints the exact fix instead of
failing silently. For a machine with no CUDA toolkit at all, use the
`-cublas.zip` which bundles `cublas*.dll`.

## Why these build flags

| Flag | Effect |
|------|--------|
| `-DCMAKE_CUDA_ARCHITECTURES=75` | Turing only (2060/2070/2080/Titan Xp). Biggest size cut — `ggml-cuda.dll` goes from ~545 MB (multi-arch) to ~60-100 MB. |
| `-DGGML_STATIC=ON` | cudart is **statically linked**, so `cudart64_12.dll` is not needed at runtime. |
| cuBLAS stays a DLL | NVIDIA ships **no** static `cublas.lib` for Windows (see upstream `ggml/src/ggml-cuda/CMakeLists.txt`: *"CUDA Toolkit for Windows does not offer a static cublas library"*). `ggml-cuda.dll` links `cudart_static` + dynamic `cublas`. |
| `-DGGML_NATIVE=OFF` `-DGGML_OPENMP=OFF` | one baseline CPU backend (the multi-variant matrix is off). |
| `-DWHISPER_BUILD_TESTS=OFF` `-DWHISPER_BUILD_SERVER=OFF` `-DWHISPER_SDL2=OFF` | examples, tests, server and SDL2 are off. |

Kernels are nvcc-compiled to sm_75 SASS at build time (no runtime JIT/NVRTC):
instant cold start, and the binary is tied to the CUDA 12.9 build.

## Host requirements (the 2060 box)

- Windows 10 x64, NVIDIA GPU driver installed (provides `nvcuda.dll`).
- CUDA 12.9 toolkit installed, so `CUDA_PATH_V12_9` points at it (the toolkit
  sets this automatically; it exists specifically so apps like whisper can find
  the 12.9 runtime). Pinning to 12.9 keeps the cuBLAS ABI match exact.
- The model (e.g. `ggml-large-v3-turbo.bin`) sits separately — it is **not**
  bundled in the zip.

## Usage

```bat
cd c:\path\to\release
whisper.bat -m your-model.bin -f audio.wav -l en
```

Or call `whisper-cli.exe` directly if you already have CUDA 12.9 on `PATH`.

## CI / auto-updates

`.github/workflows/auto-rebuild.yml`:

- **Weekly** (`schedule`): Tuesday 09:00 UTC — polls `ggml-org/whisper.cpp` master.
- **`workflow_dispatch`** — manual; pass `upstream_sha` (optional) and `force`
  to rebuild a specific/published SHA.

On a new SHA it: (1) shallow-fetches upstream at that SHA (ggml is vendored, no
submodules), (2) installs CUDA 12.9 via `Jimver/cuda-toolkit`, (3) configures +
builds `--target whisper-cli`, (4) runs the **CPU smoke test** (`ggml-tiny.en.bin`
on `samples/jfk.wav` — the runner has no GPU, so this exercises the CPU fallback
path and confirms the DLL closure actually loads), (5) only on pass, packages +
publishes the Release and self-commits the SHA.
