#!/usr/bin/env bash
# setup_q4km.sh — one-shot setup for OmniVoice GGUF Q4_K_M on Windows (Git Bash).
# Idempotent: safe to re-run, each step skips if already done.
#
# Usage: узнайте compute capability своей видеокарты (nvidia-smi / таблица NVIDIA),
#        затем:
#   CUDA_ARCH=61 ./setup_q4km.sh          # 61 = Pascal (GTX 10xx)
#   CUDA_ARCH=75 ./setup_q4km.sh          # 75 = Turing (RTX 20xx / GTX 16xx)
#   CUDA_ARCH=86 ./setup_q4km.sh          # 86 = Ampere (RTX 30xx)
#   CUDA_ARCH=89 ./setup_q4km.sh          # 89 = Ada (RTX 40xx)
#
# После скрипта в директории будут: ptmaker.py, tts.py, папки ref/,
# synthesized/, tosintez.txt, и engine/ (всё техническое — CUDA, сборка,
# модели — трогать не нужно). Дальше — положите референс в ref/,
# впишите текст в ref/text_ref.txt и tosintez.txt — см. инструкцию в конце.

set -euo pipefail

PROJECT_DIR="${PROJECT_DIR:-$(pwd)}"
ENGINE_DIR="$PROJECT_DIR/engine"
CUDA_ARCH="${CUDA_ARCH:-61}"                       # 61 = Pascal (GTX 10xx). 75=Turing, 86=Ampere, 89=Ada.
CUDA_VERSION="${CUDA_VERSION:-12.6.3}"
CUDA_INSTALLER_URL="https://developer.download.nvidia.com/compute/cuda/${CUDA_VERSION}/local_installers/cuda_${CUDA_VERSION}_561.17_windows.exe"
VS_BUILDTOOLS_PATH="${VS_BUILDTOOLS_PATH:-C:\\BuildTools2022}"
SCRATCH="${PROJECT_DIR}/.setup_scratch"

log()  { echo -e "\n\033[1;36m==> $*\033[0m"; }
skip() { echo "    (already done, skipping) $*"; }

mkdir -p "$SCRATCH" "$ENGINE_DIR"
cd "$PROJECT_DIR"

# ---------------------------------------------------------------------------
log "1/9  Python 3.10+ (needed by ptmaker.py/tts.py)"
PY_OK=0
if command -v python >/dev/null 2>&1; then
    PY_VER=$(python -c "import sys; print('%d.%d' % sys.version_info[:2])" 2>/dev/null || echo "0.0")
    PY_MAJOR=${PY_VER%%.*}
    PY_MINOR=${PY_VER##*.}
    if [ "$PY_MAJOR" -eq 3 ] && [ "$PY_MINOR" -ge 10 ]; then
        PY_OK=1
    fi
fi
if [ "$PY_OK" -eq 1 ]; then
    skip "python $PY_VER"
else
    powershell.exe -NoProfile -Command \
        "winget install --id Python.Python.3.12 -e --silent --accept-package-agreements --accept-source-agreements"
    echo "    Python установлен. Если следующий шаг не находит 'python' — закройте и заново"
    echo "    откройте Git Bash (PATH подхватится только в новом окне терминала), затем"
    echo "    перезапустите этот скрипт: ./setup_q4km.sh"
    exit 0
fi

# ---------------------------------------------------------------------------
log "2/9  CMake"
if command -v cmake >/dev/null 2>&1 || find "/c/Program Files (x86)/Microsoft Visual Studio" -iname cmake.exe 2>/dev/null | grep -q .; then
    skip "cmake"
else
    powershell.exe -NoProfile -Command \
        "winget install --id Kitware.CMake -e --silent --accept-package-agreements --accept-source-agreements"
fi

# ---------------------------------------------------------------------------
log "3/9  VS2022 Build Tools (C++ toolchain CUDA is actually tested against)"
if [ -f "$(cygpath -u "$VS_BUILDTOOLS_PATH")/VC/Auxiliary/Build/vcvars64.bat" ] 2>/dev/null; then
    skip "VS2022 Build Tools at $VS_BUILDTOOLS_PATH"
else
    BOOTSTRAP="$SCRATCH/vs_buildtools.exe"
    [ -f "$BOOTSTRAP" ] || powershell.exe -NoProfile -Command \
        "Invoke-WebRequest -Uri 'https://aka.ms/vs/17/release/vs_buildtools.exe' -OutFile '$(cygpath -w "$BOOTSTRAP")' -UseBasicParsing"
    echo "    Installing VS2022 C++ build tools (elevated — approve the UAC prompt if it appears)..."
    powershell.exe -NoProfile -Command "
        \$p = Start-Process -FilePath '$(cygpath -w "$BOOTSTRAP")' -ArgumentList '--quiet --wait --norestart --nocache --installPath \"$VS_BUILDTOOLS_PATH\" --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended' -Verb RunAs -PassThru -Wait
        exit \$p.ExitCode
    "
fi

# ---------------------------------------------------------------------------
log "4/9  7-Zip + ffmpeg"
SEVENZIP="/c/Program Files/7-Zip/7z.exe"
if [ -f "$SEVENZIP" ]; then
    skip "7-Zip"
else
    powershell.exe -NoProfile -Command \
        "winget install --id 7zip.7zip -e --silent --accept-package-agreements --accept-source-agreements"
fi
if command -v ffmpeg >/dev/null 2>&1; then
    skip "ffmpeg"
else
    powershell.exe -NoProfile -Command \
        "winget install --id Gyan.FFmpeg -e --silent --accept-package-agreements --accept-source-agreements"
fi

# ---------------------------------------------------------------------------
log "5/9  CUDA Toolkit ${CUDA_VERSION} (manual extraction — official installer conflicts with existing driver)"
CUDA_TARGET="$ENGINE_DIR/cuda-toolkit-12.6"
if [ -x "$CUDA_TARGET/bin/nvcc.exe" ]; then
    skip "CUDA toolkit at $CUDA_TARGET"
else
    CUDA_INSTALLER="$SCRATCH/cuda_installer.exe"
    if [ ! -f "$CUDA_INSTALLER" ]; then
        echo "    Downloading CUDA installer (~3.2GB)..."
        powershell.exe -NoProfile -Command \
            "Invoke-WebRequest -Uri '$CUDA_INSTALLER_URL' -OutFile '$(cygpath -w "$CUDA_INSTALLER")' -UseBasicParsing"
    fi

    CUDA_EXTRACT="$SCRATCH/cuda-extract"
    rm -rf "$CUDA_EXTRACT"; mkdir -p "$CUDA_EXTRACT"
    (cd "$CUDA_EXTRACT" && "$SEVENZIP" x "$CUDA_INSTALLER" -o. -y \
        "cuda_nvcc*" "cuda_cudart*" "libcublas*" "cuda_cccl*" "cuda_nvtx*" >/dev/null)

    mkdir -p "$CUDA_TARGET"/{bin,include,lib/x64,nvvm}
    cp -r "$CUDA_EXTRACT/cuda_nvcc/nvcc/bin/."         "$CUDA_TARGET/bin/"
    cp -r "$CUDA_EXTRACT/cuda_nvcc/nvcc/include/."     "$CUDA_TARGET/include/"
    cp -r "$CUDA_EXTRACT/cuda_nvcc/nvcc/lib/x64/."     "$CUDA_TARGET/lib/x64/"
    cp -r "$CUDA_EXTRACT/cuda_nvcc/nvcc/nvvm/."        "$CUDA_TARGET/nvvm/"
    cp -r "$CUDA_EXTRACT/cuda_cudart/cudart/bin/."     "$CUDA_TARGET/bin/"
    cp -r "$CUDA_EXTRACT/cuda_cudart/cudart/include/." "$CUDA_TARGET/include/"
    cp -r "$CUDA_EXTRACT/cuda_cudart/cudart/lib/x64/." "$CUDA_TARGET/lib/x64/"
    cp -r "$CUDA_EXTRACT/libcublas/cublas/bin/."       "$CUDA_TARGET/bin/"
    cp -r "$CUDA_EXTRACT/libcublas/cublas_dev/include/." "$CUDA_TARGET/include/"
    cp -r "$CUDA_EXTRACT/libcublas/cublas_dev/lib/x64/." "$CUDA_TARGET/lib/x64/"
    cp -r "$CUDA_EXTRACT/cuda_cccl/thrust/include/."   "$CUDA_TARGET/include/"
    cp -r "$CUDA_EXTRACT/cuda_nvtx/nvtx/include/."     "$CUDA_TARGET/include/"
    rm -rf "$CUDA_EXTRACT"

    "$CUDA_TARGET/bin/nvcc.exe" --version
fi

# ---------------------------------------------------------------------------
log "6/9  Clone + build omnivoice.cpp (CUDA backend, sm_${CUDA_ARCH})"
REPO_DIR="$ENGINE_DIR/omnivoice.cpp"
if [ ! -d "$REPO_DIR" ]; then
    git clone --recurse-submodules https://github.com/ServeurpersoCom/omnivoice.cpp.git "$REPO_DIR"
fi

if [ -x "$REPO_DIR/build/omnivoice-tts.exe" ] && [ -x "$REPO_DIR/build/omnivoice-codec.exe" ]; then
    skip "omnivoice.cpp build"
else
    BUILD_CMD="$REPO_DIR/buildcuda_manual.cmd"
    cat > "$BUILD_CMD" <<EOF
@echo off
cd /d %~dp0
call "${VS_BUILDTOOLS_PATH}\\VC\\Auxiliary\\Build\\vcvars64.bat"

set CUDA_PATH=$(cygpath -w "$CUDA_TARGET")
set PATH=%CUDA_PATH%\\bin;%CUDA_PATH%\\nvvm\\bin;%PATH%

mkdir build 2>nul
cd build
cmake .. -G Ninja -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=${CUDA_ARCH}
cmake --build . -j %NUMBER_OF_PROCESSORS%
cd ..
EOF
    MSYS_NO_PATHCONV=1 cmd.exe /c "$(cygpath -w "$BUILD_CMD")"

    if [ ! -x "$REPO_DIR/build/omnivoice-tts.exe" ] || [ ! -x "$REPO_DIR/build/omnivoice-codec.exe" ]; then
        echo "ОШИБКА: сборка omnivoice.cpp не создала omnivoice-tts.exe / omnivoice-codec.exe." >&2
        echo "Смотрите вывод cmake/ninja выше — вероятно ошибка компиляции." >&2
        exit 1
    fi

    # Runtime DLLs — copy next to the exes so they run standalone.
    REDIST="$(cygpath -u "$VS_BUILDTOOLS_PATH")/VC/Redist/MSVC"
    # Skip "v143" etc (installer-only folders with no DLLs) -- pick the numeric version dir.
    REDIST_VER=$(find "$REDIST" -maxdepth 1 -mindepth 1 -type d ! -iname 'v*' | sort -V | tail -1)
    cp "$REDIST_VER/x64/Microsoft.VC143.CRT/"*.dll "$REPO_DIR/build/"
    cp "$REDIST_VER/x64/Microsoft.VC143.OpenMP/"*.dll "$REPO_DIR/build/"
    cp "$(cygpath -u "$VS_BUILDTOOLS_PATH")/Common7/IDE/"api-ms-win-crt-*.dll "$REPO_DIR/build/"
    cp "$(cygpath -u "$VS_BUILDTOOLS_PATH")/Common7/IDE/ucrtbase.dll" "$REPO_DIR/build/"
    cp "$CUDA_TARGET/bin/cudart64_12.dll" "$CUDA_TARGET/bin/cublas64_12.dll" \
       "$CUDA_TARGET/bin/cublasLt64_12.dll" "$CUDA_TARGET/nvvm/bin/nvvm64_40_0.dll" "$REPO_DIR/build/"
fi

# ---------------------------------------------------------------------------
log "7/9  Download Q4_K_M GGUF files"
GGUF_DIR="$ENGINE_DIR/omnivoice-gguf"
mkdir -p "$GGUF_DIR"
if [ -f "$GGUF_DIR/omnivoice-base-Q4_K_M.gguf" ] && [ -f "$GGUF_DIR/omnivoice-tokenizer-Q4_K_M.gguf" ]; then
    skip "Q4_K_M gguf files"
else
    if ! command -v hf >/dev/null 2>&1; then
        echo "    'hf' CLI not found — installing huggingface_hub..."
        pip install -U "huggingface_hub[cli]"
    fi
    hf download Serveurperso/OmniVoice-GGUF \
        omnivoice-base-Q4_K_M.gguf omnivoice-tokenizer-Q4_K_M.gguf \
        --local-dir "$GGUF_DIR"
fi

# ---------------------------------------------------------------------------
log "8/9  Python deps (omnivoice, soundfile — needed by ptmaker.py/tts.py)"
if python -c "import omnivoice, soundfile" >/dev/null 2>&1; then
    skip "python deps"
else
    pip install omnivoice soundfile
fi

# ---------------------------------------------------------------------------
log "9/9  Write ptmaker.py / tts.py"
if [ -f "$PROJECT_DIR/ptmaker.py" ] && [ -f "$PROJECT_DIR/tts.py" ]; then
    skip "ptmaker.py / tts.py"
else

cat > "$PROJECT_DIR/ptmaker.py" <<'PTMAKER_EOF'
"""
ptmaker.py - create a reusable voice-clone prompt (.rvq) from a reference
audio clip, using the OmniVoice GGUF/Q4_K_M backend (omnivoice.cpp).

Put your reference recording at:
    ref/audio_ref.mp3   (or ref/audio_ref.wav -- either works, mp3 is
                          auto-converted)
and the EXACT text spoken in it at:
    ref/text_ref.txt

Then just run:
    python ptmaker.py

This writes engine/omnivoice-gguf/my_voice.rvq (+ a sidecar .txt), which
tts.py then uses to synthesize speech in that voice. Everything under
engine/ is internal machinery (models, the compiled backend) -- you never
need to open it.
"""

import argparse
import shutil
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
ENGINE_DIR = REPO_ROOT / "engine"

REF_DIR = REPO_ROOT / "ref"
REF_TEXT_FILE = REF_DIR / "text_ref.txt"
REF_AUDIO_WAV = REF_DIR / "audio_ref.wav"
REF_AUDIO_MP3 = REF_DIR / "audio_ref.mp3"

GGUF_DIR = ENGINE_DIR / "omnivoice-gguf"
CODEC_EXE = ENGINE_DIR / "omnivoice.cpp" / "build" / "omnivoice-codec.exe"
DEFAULT_OUT = "engine/omnivoice-gguf/my_voice.rvq"

QUANT = "Q4_K_M"


def default_ref_audio():
    """Prefer an existing .wav; fall back to .mp3 (auto-converted later)."""
    if REF_AUDIO_WAV.exists():
        return REF_AUDIO_WAV
    if REF_AUDIO_MP3.exists():
        return REF_AUDIO_MP3
    sys.exit(
        "no reference audio found. Drop your recording at "
        f"{REF_AUDIO_WAV} or {REF_AUDIO_MP3} (.mp3 or .wav)."
    )


def default_ref_text():
    if not REF_TEXT_FILE.exists():
        sys.exit(f"no reference transcript found. Write it into {REF_TEXT_FILE}")
    text = REF_TEXT_FILE.read_text(encoding="utf-8").strip()
    if not text:
        sys.exit(f"{REF_TEXT_FILE} is empty -- write the exact text spoken in the reference audio.")
    return text


def ensure_wav(path: Path) -> Path:
    """omnivoice-codec.exe needs WAV input; auto-convert anything else via ffmpeg."""
    if path.suffix.lower() == ".wav":
        return path
    wav_path = path.with_suffix(".wav")
    if not wav_path.exists():
        print(f"converting {path.name} -> {wav_path.name} (ffmpeg)")
        subprocess.run(
            ["ffmpeg", "-y", "-i", str(path), "-ar", "24000", "-ac", "1", str(wav_path)],
            check=True, capture_output=True,
        )
    return wav_path


def make_prompt(args):
    codec_gguf = args.gguf_dir / f"omnivoice-tokenizer-{QUANT}.gguf"

    for p, label in [(codec_gguf, "tokenizer gguf"), (args.codec_exe, "omnivoice-codec.exe"),
                      (args.ref_audio, "reference audio")]:
        if not p.exists():
            sys.exit(f"missing {label}: {p}")

    ref_audio = ensure_wav(args.ref_audio)

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    # omnivoice-codec auto-names its output next to the *input* wav
    # (clip.wav -> clip.rvq), so encode next to the ref audio, then move
    # the result to the requested --out path.
    cmd = [str(args.codec_exe), "--model", str(codec_gguf), "-i", str(ref_audio)]
    print(f"encoding reference: {' '.join(cmd)}")
    subprocess.run(cmd, check=True)

    produced_rvq = ref_audio.with_suffix(".rvq")
    if not produced_rvq.exists():
        sys.exit(f"expected omnivoice-codec output not found: {produced_rvq}")
    shutil.move(str(produced_rvq), str(out))

    # Sidecar transcript file, required by tts.py --ref-text at synthesis time.
    ref_text_path = out.with_suffix(".txt")
    ref_text_path.write_text(args.ref_text, encoding="utf-8")

    print(f"saved voice prompt -> {out}")
    print(f"saved reference transcript -> {ref_text_path}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=DEFAULT_OUT, help="Path to write the voice prompt .rvq")
    ap.add_argument("--ref-text", default=None, help="Transcript matching --ref-audio (defaults to ref/text_ref.txt)")
    ap.add_argument("--ref-audio", type=Path, default=None,
                     help="Reference audio (.mp3 or .wav). Defaults to ref/audio_ref.{wav,mp3}")
    ap.add_argument("--gguf-dir", type=Path, default=GGUF_DIR, help="directory with the .gguf files")
    ap.add_argument("--codec-exe", type=Path, default=CODEC_EXE, help="path to omnivoice-codec.exe")

    args = ap.parse_args()

    if args.ref_audio is None:
        args.ref_audio = default_ref_audio()
    if args.ref_text is None:
        args.ref_text = default_ref_text()
    make_prompt(args)


if __name__ == "__main__":
    main()
PTMAKER_EOF

cat > "$PROJECT_DIR/tts.py" <<'TTS_EOF'
"""
tts.py - generate speech in a cloned voice from a .rvq prompt made by
ptmaker.py, using the OmniVoice GGUF/Q4_K_M backend (omnivoice.cpp).

Write the text you want spoken into:
    tosintez.txt

Then just run:
    python tts.py

Each run writes a new file into synthesized/, named after the exact date
and time of the run (so nothing gets overwritten). Everything under
engine/ is internal machinery (models, the compiled backend) -- you never
need to open it.
"""

import argparse
import subprocess
import sys
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent
ENGINE_DIR = REPO_ROOT / "engine"

TEXT_FILE = REPO_ROOT / "tosintez.txt"
SYNTH_DIR = REPO_ROOT / "synthesized"

GGUF_DIR = ENGINE_DIR / "omnivoice-gguf"
TTS_EXE = ENGINE_DIR / "omnivoice.cpp" / "build" / "omnivoice-tts.exe"
DEFAULT_RVQ = "engine/omnivoice-gguf/my_voice.rvq"
DEFAULT_LANG = "Russian"

QUANT = "Q4_K_M"


def default_text():
    if not TEXT_FILE.exists():
        sys.exit(f"no text to synthesize found. Write it into {TEXT_FILE}")
    text = TEXT_FILE.read_text(encoding="utf-8").strip()
    if not text:
        sys.exit(f"{TEXT_FILE} is empty -- write the text you want spoken.")
    return text


def default_out() -> Path:
    SYNTH_DIR.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    return SYNTH_DIR / f"{stamp}.wav"


def run_tts(args):
    base_gguf = args.gguf_dir / f"omnivoice-base-{QUANT}.gguf"
    codec_gguf = args.gguf_dir / f"omnivoice-tokenizer-{QUANT}.gguf"
    ref_text_path = args.rvq.with_suffix(".txt")

    for p, label in [(base_gguf, "base gguf"), (codec_gguf, "tokenizer gguf"),
                      (args.tts_exe, "omnivoice-tts.exe"), (args.rvq, "voice prompt .rvq"),
                      (ref_text_path, "reference transcript .txt (from ptmaker.py)")]:
        if not p.exists():
            sys.exit(f"missing {label}: {p}")

    out = Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    cmd = [
        str(args.tts_exe),
        "--model", str(base_gguf),
        "--codec", str(codec_gguf),
        "--ref-rvq", str(args.rvq),
        "--ref-text", str(ref_text_path),
        "--lang", args.lang,
        "-o", str(out),
    ]
    print(f"{' '.join(cmd)}")
    subprocess.run(cmd, input=args.text, text=True, check=True)
    print(f"wrote -> {out}")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--text", default=None, help="Text to synthesize (defaults to tosintez.txt)")
    ap.add_argument("--out", default=None, help="Output .wav path (defaults to synthesized/<timestamp>.wav)")
    ap.add_argument("--lang", default=DEFAULT_LANG)
    ap.add_argument("--gguf-dir", type=Path, default=GGUF_DIR, help="directory with the .gguf files")
    ap.add_argument("--tts-exe", type=Path, default=TTS_EXE, help="path to omnivoice-tts.exe")
    ap.add_argument("--rvq", type=Path, default=Path(DEFAULT_RVQ), help="path to the .rvq voice prompt from ptmaker.py")

    args = ap.parse_args()
    if args.text is None:
        args.text = default_text()
    if args.out is None:
        args.out = default_out()
    run_tts(args)


if __name__ == "__main__":
    main()
TTS_EOF

fi

# ---------------------------------------------------------------------------
mkdir -p "$PROJECT_DIR/ref" "$PROJECT_DIR/synthesized"
[ -f "$PROJECT_DIR/tosintez.txt" ] || echo "Привет, а ты любишь Large Language Models?" > "$PROJECT_DIR/tosintez.txt"

echo -e "\n\033[1;32mГотово: CMake, VS2022 Build Tools, CUDA, omnivoice.cpp, Q4_K_M модели (всё в engine/), ptmaker.py, tts.py.\033[0m"
echo -e "\033[1;33m\nСледующие шаги (вручную):\033[0m"
echo "  1. Положите референс своего голоса сюда:"
echo "       ref/audio_ref.mp3   (или .wav)"
echo "  2. Впишите в ref/text_ref.txt ТОЧНО тот текст, что произносится в референсе."
echo "  3. Создайте голосовой промпт:"
echo "       python ptmaker.py"
echo "  4. Впишите нужный текст в tosintez.txt и запустите:"
echo "       python tts.py"
echo "     Результат появится в synthesized/ с именем по дате и времени."
