#!/usr/bin/env bash
set -euo pipefail

export PATH="/home/ubuntu/flutter/bin:/home/ubuntu/.local/bin:${PATH}"

ensure_toolchains() {
  if ! command -v dart >/dev/null 2>&1; then
    if [ ! -d "$HOME/flutter" ]; then
      echo "==> installing Flutter stable"
      git clone --depth 1 --branch stable https://github.com/flutter/flutter.git "$HOME/flutter"
      "$HOME/flutter/bin/flutter" config --no-analytics
      "$HOME/flutter/bin/flutter" precache --linux
    fi
    export PATH="$HOME/flutter/bin:$PATH"
  fi

  if ! command -v uv >/dev/null 2>&1; then
    echo "==> installing uv"
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
    uv python install 3.13
  fi
}

ensure_toolchains

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
