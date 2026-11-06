#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p vendor .build
download() {
    local file="$1" url="$2" expected="$3"
    if [[ ! -f "$file" ]]; then
        curl -fL --retry 2 --connect-timeout 15 "$url" -o "$file.download"
        mv "$file.download" "$file"
    fi
    local actual
    actual="$(shasum -a 256 "$file" | cut -d ' ' -f 1)"
    if [[ "$actual" != "$expected" ]]; then echo "SHA-256 校验失败：$file" >&2; exit 1; fi
}
download vendor/scrcpy-macos-aarch64-v5.0.1.tar.gz \
    https://github.com/Genymobile/scrcpy/releases/download/v5.0.1/scrcpy-macos-aarch64-v5.0.1.tar.gz \
    33611e51977a8289e2e124b220f727895181ef2eb9060e0987a4dc2db9cf0d6b
download vendor/ffmpeg-n9.0.2.tar.gz https://codeload.github.com/FFmpeg/FFmpeg/tar.gz/refs/tags/n9.0.2 \
    6e374ed621e48faa40639307dff48ba6fe574a509977956d2cce9669b7cc27e9
if [[ ! -x /opt/homebrew/bin/pkg-config || ! -f /opt/homebrew/opt/sdl3/lib/libSDL3.0.dylib ]]; then
    echo "编译依赖：brew install pkgconf sdl3" >&2; exit 1
fi
if [[ ! -x .build/tools/bin/meson ]]; then
    python3 -m venv .build/tools
    .build/tools/bin/pip install 'meson==1.12.1' 'ninja==1.13.0'
fi
if [[ ! -f .build/ffmpeg-install/lib/libavcodec.63.dylib ]]; then
    mkdir -p .build/ffmpeg-src
    tar -xzf vendor/ffmpeg-n9.0.2.tar.gz --strip-components=1 -C .build/ffmpeg-src
    prefix="$(pwd)/.build/ffmpeg-install"
    (
        cd .build/ffmpeg-src
        ./configure --prefix="$prefix" --disable-everything --disable-autodetect \
            --disable-gpl --disable-nonfree --disable-version3 \
            --disable-programs --disable-doc --disable-network --disable-avdevice --disable-avfilter \
            --disable-swscale --disable-static --enable-shared --enable-pic \
            --enable-decoder=h264,hevc,opus,aac,flac,pcm_s16le,png \
            --enable-muxer=mp4,matroska,opus,flac,wav --enable-demuxer=image2 \
            --enable-parser=h264,hevc,png --enable-protocol=file --enable-videotoolbox \
            --enable-hwaccel=h264_videotoolbox,hevc_videotoolbox --enable-zlib
        make -j8
        make install
    )
fi
if ! grep -q '^#define CONFIG_GPL 0$' .build/ffmpeg-src/config.h || \
   ! grep -q '^#define CONFIG_NONFREE 0$' .build/ffmpeg-src/config.h || \
   ! grep -q '^#define CONFIG_VERSION3 0$' .build/ffmpeg-src/config.h; then
    echo "拒绝打包：FFmpeg GPL/nonfree/version3 配置不符合要求。" >&2; exit 1
fi
