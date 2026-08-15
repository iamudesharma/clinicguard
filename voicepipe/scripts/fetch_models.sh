#!/usr/bin/env bash
# Downloads the speech models for the voicepipe agent (silero VAD, whisper
# tiny multilingual, piper en_US-lessac-medium int8) + a test wav.
# Run from voicepipe/. Output: models/
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p models
cd models

fetch() { # url
  local f="${1##*/}"
  if [ -e "$f" ]; then echo "have $f"; else
    echo "downloading $f ..."
    curl -SL "$1" -o "$f"
  fi
}

# VAD (628 KB)
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"

# Whisper tiny multilingual (encoder+decoder int8; ~110 MB) — default
fetch_whisper() { # prefix (tiny|base)
  local prefix="$1"
  if [ ! -d "sherpa-onnx-whisper-$prefix" ]; then
    echo "downloading sherpa-onnx-whisper-$prefix.tar.bz2 ..."
    curl -SL "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-whisper-$prefix.tar.bz2" -o "sherpa-onnx-whisper-$prefix.tar.bz2"
    tar xjf "sherpa-onnx-whisper-$prefix.tar.bz2"
    rm "sherpa-onnx-whisper-$prefix.tar.bz2"
  fi
}

fetch_whisper tiny
# Optional: better accuracy, ~2.5x memory (set VOICEPIPE_WHISPER_MODEL=base)
# fetch_whisper base

# Piper en_US-lessac-medium (int8; ~19 MB)
if [ ! -d vits-piper-en_US-lessac-medium-int8 ]; then
  echo "downloading vits-piper-en_US-lessac-medium-int8.tar.bz2 ..."
  curl -SL "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium-int8.tar.bz2" -o vits-piper-en_US-lessac-medium-int8.tar.bz2
  tar xjf vits-piper-en_US-lessac-medium-int8.tar.bz2
  rm vits-piper-en_US-lessac-medium-int8.tar.bz2
fi

# Test audio (Obama.wav, 16 kHz mono, ~10 MB)
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/Obama.wav"

echo
echo "models ready in $(pwd):"
du -sh *
