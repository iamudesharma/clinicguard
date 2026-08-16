FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/root/flutter/bin:/root/.local/bin:${PATH}"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      clang \
      cmake \
      curl \
      git \
      libgtk-3-dev \
      libopus0 \
      ninja-build \
      pkg-config \
      unzip \
      xz-utils \
      zip \
    && rm -rf /var/lib/apt/lists/*

# Flutter stable (includes Dart SDK >= 3.13 for this workspace).
RUN git clone --depth 1 --branch stable https://github.com/flutter/flutter.git /root/flutter \
    && flutter --version \
    && flutter config --no-analytics \
    && flutter precache

# uv + Python 3.13 (server/.python-version).
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && uv python install 3.13

USER ubuntu
