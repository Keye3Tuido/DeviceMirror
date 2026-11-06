#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
"""Build runtime dependencies for the same minimum macOS as the app."""
import hashlib
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent
TARGET = os.environ.get('MACOSX_DEPLOYMENT_TARGET', '13.0')
PREFIX = ROOT / '.build' / 'portable-deps' / ('macos' + TARGET) / 'install'
PACKAGES = [
    ('abseil', '20260817.0', 'https://github.com/abseil/abseil-cpp/archive/refs/tags/20260817.0.tar.gz', 'f7e05179df39c45434cad433f5783840bb3788ef322976f9138bc6b72b3a107d', '.', ['-DABSL_BUILD_TESTING=OFF', '-DABSL_PROPAGATE_CXX_STD=ON']),
    ('protobuf', '36.2', 'https://github.com/protocolbuffers/protobuf/releases/download/v36.2/protobuf-36.2.tar.gz', '3d9642a662d10e68ebae5e53f14dcce5105684212d5078f8e0d47d1ab3ae6b64', '.', ['-Dprotobuf_BUILD_TESTS=OFF', '-Dprotobuf_ABSL_PROVIDER=package', '-Dprotobuf_BUILD_PROTOC_BINARIES=OFF', '-Dprotobuf_BUILD_LIBPROTOC=OFF']),
    ('brotli', '1.2.1', 'https://github.com/google/brotli/archive/refs/tags/v1.2.1.tar.gz', '98d35d11a78dc453aebb7d10c3748f3f73ff78c8267c0dc697b8631f67bf7e8f', '.', ['-DBROTLI_DISABLE_TESTS=ON']),
    ('lz4', '1.10.0', 'https://github.com/lz4/lz4/archive/refs/tags/v1.10.0.tar.gz', '537512904744b35e232912055ccf8ec66d768639ff3abe5788d90d792ec5f48b', 'build/cmake', ['-DLZ4_BUILD_CLI=OFF', '-DLZ4_BUILD_LEGACY_LZ4C=OFF']),
    ('zstd', '1.5.7', 'https://github.com/facebook/zstd/archive/refs/tags/v1.5.7.tar.gz', '37d7284556b20954e56e1ca85b80226768902e2edabd3b649e9e72c0c9012ee3', 'build/cmake', ['-DZSTD_BUILD_PROGRAMS=OFF', '-DZSTD_BUILD_TESTS=OFF', '-DZSTD_BUILD_STATIC=OFF']),
    ('sdl3', '3.4.20', 'https://github.com/libsdl-org/SDL/releases/download/release-3.4.20/SDL3-3.4.20.tar.gz', 'f3bb06f55bed9557227a700af2ea62e49497ebdf58037732a731a5fb3ef8581f', '.', ['-DSDL_SHARED=ON', '-DSDL_STATIC=OFF', '-DSDL_TESTS=OFF', '-DSDL_TEST_LIBRARY=OFF']),
]


def build():
    env = os.environ.copy()
    for key in ('CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'OBJC_INCLUDE_PATH', 'LIBRARY_PATH', 'SDKROOT'):
        env.pop(key, None)
    env['MACOSX_DEPLOYMENT_TARGET'] = TARGET
    work = PREFIX.parent
    archives = ROOT / 'vendor'
    archives.mkdir(exist_ok=True)
    for name, version, url, checksum, subdir, options in PACKAGES:
        archive = archives / (name + '-' + version + '.tar.gz')
        if not archive.exists():
            temporary = archive.with_suffix('.download')
            subprocess.run(['curl', '-fL', '--retry', '3', '--retry-all-errors', '--connect-timeout', '15', '--max-time', '180', url, '-o', str(temporary)], check=True)
            temporary.replace(archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != checksum:
            raise SystemExit('Source checksum mismatch: ' + str(archive))
        stamp = work / (name + '.complete')
        if stamp.exists() and stamp.read_text() == checksum:
            continue
        source = work / (name + '-src')
        source.mkdir(parents=True, exist_ok=True)
        subprocess.run(['tar', '-xf', str(archive), '--strip-components=1', '-C', str(source)], check=True)
        build_dir = work / (name + '-build')
        args = ['cmake', '-S', str(source / subdir), '-B', str(build_dir), '-G', 'Ninja',
                '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_CXX_STANDARD=17', '-DBUILD_SHARED_LIBS=ON',
                '-DCMAKE_OSX_ARCHITECTURES=arm64', '-DCMAKE_OSX_DEPLOYMENT_TARGET=' + TARGET,
                '-DCMAKE_C_FLAGS=-Werror=unguarded-availability-new',
                '-DCMAKE_CXX_FLAGS=-Werror=unguarded-availability-new',
                '-DCMAKE_INSTALL_PREFIX=' + str(PREFIX), '-DCMAKE_INSTALL_LIBDIR=lib',
                '-DCMAKE_PREFIX_PATH=' + str(PREFIX), *options]
        subprocess.run(args, env=env, check=True)
        subprocess.run(['cmake', '--build', str(build_dir), '-j6'], env=env, check=True)
        subprocess.run(['cmake', '--install', str(build_dir)], env=env, check=True)
        notices = PREFIX / 'share' / 'licenses' / name
        notices.mkdir(parents=True, exist_ok=True)
        for path in source.rglob('*'):
            if path.is_file() and path.name.lower().startswith(('license', 'copying', 'notice', 'authors')):
                destination = notices / path.relative_to(source)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(path, destination)
        stamp.write_text(checksum)


if __name__ == '__main__':
    build()
