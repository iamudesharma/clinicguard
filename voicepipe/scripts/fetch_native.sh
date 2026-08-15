#!/usr/bin/env bash
# Downloads the prebuilt sherpa-onnx native library for the current platform.
# Run from voicepipe/. Output: third_party/native/<os-arch>/libsherpa-onnx-c-api.dylib
set -euo pipefail
cd "$(dirname "$0")/.."

VER=1.13.5
case "$(uname -s)-$(uname -m)" in
  Darwin-arm64) ASSET="sherpa-onnx-v${VER}-osx-arm64-shared.tar.bz2"; DIR="sherpa-onnx-v${VER}-osx-arm64-shared";;
  Darwin-x86_64) ASSET="sherpa-onnx-v${VER}-osx-x64-shared.tar.bz2"; DIR="sherpa-onnx-v${VER}-osx-x64-shared";;
  Linux-x86_64) ASSET="sherpa-onnx-v${VER}-linux-x64-shared.tar.bz2"; DIR="sherpa-onnx-v${VER}-linux-x64-shared";;
  *) echo "unsupported platform: $(uname -s)-$(uname -m)"; exit 1;;
esac

OUT="third_party/native/$(echo "$(uname -s)" | tr '[:upper:]' '[:lower:]')-$(uname -m)"
mkdir -p "$OUT"
if [ -f "$OUT/libsherpa-onnx-c-api.dylib" ] || [ -f "$OUT/libsherpa-onnx-c-api.so" ]; then
  echo "native lib already present in $OUT"
  exit 0
fi
echo "downloading $ASSET ..."
curl -SL "https://github.com/k2-fsa/sherpa-onnx/releases/download/v${VER}/${ASSET}" -o /tmp/${ASSET}
tar xjf /tmp/${ASSET} -C /tmp
cp /tmp/${DIR}/lib/libsherpa-onnx-c-api.dylib "$OUT/" 2>/dev/null || cp /tmp/${DIR}/lib/libsherpa-onnx-c-api.so "$OUT/"
cp /tmp/${DIR}/lib/libonnxruntime.dylib "$OUT/" 2>/dev/null || true
rm -f /tmp/${ASSET}
echo "installed to $OUT"
