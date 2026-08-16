FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      build-essential \
      ca-certificates \
      cmake \
      curl \
      git \
      libgtk-3-dev \
      libopus0 \
      ninja-build \
      pkg-config \
      sudo \
      unzip \
      xz-utils \
      zip \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -s /bin/bash -u 1000 ubuntu \
    && echo 'ubuntu ALL=(ALL) NOPASSWD:ALL' >> /etc/sudoers

USER ubuntu
WORKDIR /home/ubuntu

ENV PATH="/home/ubuntu/flutter/bin:/home/ubuntu/.local/bin:${PATH}"

# Flutter stable (Dart SDK >= 3.13 for this workspace).
RUN git clone --depth 1 --branch stable https://github.com/flutter/flutter.git /home/ubuntu/flutter \
    && flutter --version \
    && flutter config --no-analytics \
    && flutter precache

# uv + Python 3.13 (server/.python-version).
RUN curl -LsSf https://astral.sh/uv/install.sh | sh \
    && uv python install 3.13
