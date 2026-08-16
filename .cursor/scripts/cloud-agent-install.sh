#!/usr/bin/env bash
set -euo pipefail

export PATH="/home/ubuntu/flutter/bin:/home/ubuntu/.local/bin:${PATH}"

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

echo "==> voice_forge workspace"
cd "$ROOT/voice_forge"
dart pub get
dart run melos bootstrap
./scripts/fetch_native.sh
./scripts/fetch_models.sh

echo "==> Flutter app"
cd "$ROOT/app"
flutter pub get

echo "==> Python server"
cd "$ROOT/server"
if [ ! -f .env ]; then
  cp .env.example .env
fi
export CXX=g++ CC=gcc
uv sync

echo "==> install complete"
