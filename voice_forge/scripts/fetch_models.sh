#!/usr/bin/env bash
# Downloads the speech models for the voice_forge agent (silero VAD, whisper
# tiny multilingual, piper en_US-lessac-medium int8) + a test wav.
# Run from voice_forge/. Output: models/
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
# whisper-base: better accuracy for accented English (+67 MB).
# Default for the agent; override with VOICE_FORGE_WHISPER_MODEL=tiny.
fetch_whisper base

# Piper en_US-lessac-medium (int8; ~19 MB)
if [ ! -d vits-piper-en_US-lessac-medium-int8 ]; then
  echo "downloading vits-piper-en_US-lessac-medium-int8.tar.bz2 ..."
  curl -SL "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-piper-en_US-lessac-medium-int8.tar.bz2" -o vits-piper-en_US-lessac-medium-int8.tar.bz2
  tar xjf vits-piper-en_US-lessac-medium-int8.tar.bz2
  rm vits-piper-en_US-lessac-medium-int8.tar.bz2
fi

# Test audio (Obama.wav, 16 kHz mono, ~10 MB)
fetch "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/Obama.wav"

# Streaming STT: Zipformer transducer (en, int8; ~70 MB)
STREAMING_DIR="sherpa-onnx-streaming-zipformer-en-2023-06-26"
if [ ! -d "$STREAMING_DIR" ]; then
  echo "downloading $STREAMING_DIR ..."
  curl -SL "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/${STREAMING_DIR}.tar.bz2" -o "${STREAMING_DIR}.tar.bz2"
  tar xjf "${STREAMING_DIR}.tar.bz2"
  rm -f "${STREAMING_DIR}.tar.bz2"
fi

echo
echo "models ready in $(pwd):"
du -sh *
