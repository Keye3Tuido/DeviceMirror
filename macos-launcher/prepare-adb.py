#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
"""Build adb from fixed source and link replaceable LGPL libusb dynamically."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
ARCHIVES = {
    'android-tools-37.0.0p1.tar.xz': ('https://github.com/nmeum/android-tools/releases/download/37.0.0p1/android-tools-37.0.0p1.tar.xz',
        '2c6de1abe16b211c7d9f59276217e14fd9e0e18b20e331d3c84358f5dffd576e'),
    'libusb-1.0.30.tar.bz2': ('https://github.com/libusb/libusb/releases/download/v1.0.30/libusb-1.0.30.tar.bz2',
        'fea36f34f9156400209595e300840767ab1a385ede1dc7ee893015aea9c6dbaf'),
}
ENV = os.environ.copy()
for name in ('CPATH', 'C_INCLUDE_PATH', 'CPLUS_INCLUDE_PATH', 'OBJC_INCLUDE_PATH', 'LIBRARY_PATH', 'SDKROOT', 'MACOSX_DEPLOYMENT_TARGET'):
    ENV.pop(name, None)
ENV['MACOSX_DEPLOYMENT_TARGET'] = '26.0'
ENV['PATH'] = '/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin'


def run(*args, cwd=None):
    subprocess.run([str(a) for a in args], cwd=cwd, env=ENV, check=True)


def archive(name):
    url, expected = ARCHIVES[name]
    path = ROOT / name if (ROOT / name).is_file() else ROOT / 'vendor' / name
    path.parent.mkdir(exist_ok=True)
    if not path.exists():
        temporary = path.with_suffix(path.suffix + '.download')
        run('curl', '-fL', '--retry', '2', '--max-time', '180', url, '-o', temporary)
        temporary.replace(path)
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise SystemExit('Source checksum mismatch: ' + name)
    return path


def dependencies(binary):
    lines = subprocess.check_output(['/usr/bin/otool', '-L', str(binary)], text=True).splitlines()[1:]
    return [line.strip().split(' (', 1)[0] for line in lines]


def build():
    sources = {name: archive(name) for name in ARCHIVES}
    work = ROOT / '.build' / 'adb-native'
    work.mkdir(parents=True, exist_ok=True)
    usb = work / 'libusb-1.0.30'
    install = work / 'usb-install'
    if not (install / 'lib/libusb-1.0.0.dylib').exists():
        run('tar', '-xf', sources['libusb-1.0.30.tar.bz2'], '-C', work)
        run('./configure', '--disable-static', '--enable-shared', '--disable-dependency-tracking',
            '--prefix=' + str(install), cwd=usb)
        run('make', '-j6', cwd=usb)
        run('make', 'install', cwd=usb)
    ENV['PKG_CONFIG_PATH'] = str(install / 'lib/pkgconfig')
    source = work / 'android-tools-37.0.0p1'
    if not source.exists():
        run('tar', '-xf', sources['android-tools-37.0.0p1.tar.xz'], '-C', work)
        cmake = source / 'vendor/CMakeLists.txt'
        content = cmake.read_text()
        marker = 'include_directories(${PROTOBUF_INCLUDE_DIRS})'
        if content.count(marker) != 1:
            raise SystemExit('Unexpected android-tools build layout')
        cmake.write_text(content.replace(marker, marker + '\n# Device Mirror (Apache-2.0): prefer bundled BoringSSL headers.\ninclude_directories(BEFORE ${CMAKE_CURRENT_SOURCE_DIR}/boringssl/include)'))
    build_dir = work / 'build'
    run('cmake', '-S', source, '-B', build_dir, '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release',
        '-DANDROID_TOOLS_PATCH_VENDOR=OFF', '-DANDROID_TOOLS_USE_BUNDLED_FMT=ON',
        '-DANDROID_TOOLS_ADB_ENABLE_MDNS=OFF', '-DCMAKE_OSX_DEPLOYMENT_TARGET=26.0', '-DCMAKE_PREFIX_PATH=/opt/homebrew')
    run('cmake', '--build', build_dir, '--target', 'adb', '-j6')
    return build_dir / 'vendor/adb', sources


def prepare(app):
    executable, sources = build()
    helpers = app / 'Contents/Helpers'
    frameworks = app / 'Contents/Frameworks'
    notices = app / 'Contents/Resources/ThirdParty/Android-tools'
    for directory in (helpers, frameworks, notices):
        directory.mkdir(parents=True, exist_ok=True)
    shutil.copy2(executable, helpers / 'adb')
    pending = [executable]
    copied, packages = {}, {}
    while pending:
        binary = pending.pop()
        for dependency in dependencies(binary):
            if dependency.startswith(('/usr/lib/', '/System/Library/')):
                continue
            if dependency.startswith('@rpath/'):
                name = dependency.removeprefix('@rpath/')
                original = next((p.resolve() for p in (binary.parent / name, Path('/opt/homebrew/lib') / name) if p.is_file()), Path('/missing') / name)
            elif dependency.startswith('@loader_path/'):
                original = (binary.parent / dependency.removeprefix('@loader_path/')).resolve()
            else:
                original = Path(dependency).resolve()
            library_name = Path(dependency).name
            if library_name in copied:
                if copied[library_name] != original:
                    raise SystemExit('Conflicting libraries: ' + library_name)
                continue
            if not original.is_file() or not (str(original).startswith('/opt/homebrew/Cellar/') or original.is_relative_to(ROOT / '.build/adb-native/usb-install')):
                raise SystemExit('Unexpected adb dependency: ' + dependency)
            copied[library_name] = original
            shutil.copy2(original, frameworks / library_name)
            (frameworks / library_name).chmod(0o755)
            pending.append(original)
            if str(original).startswith('/opt/homebrew/Cellar/'):
                package = Path(*original.parts[:6])
                packages[package.parent.name] = package
    # Full upstream sources retain the compiled AOSP/BoringSSL/fmt copyright headers.
    for path in sources.values():
        shutil.copy2(path, notices / path.name)
    source = ROOT / '.build/adb-native/android-tools-37.0.0p1'
    shutil.copy2(source / 'LICENSE', notices / 'android-tools-Apache-2.0.txt')
    shutil.copy2(ROOT / '.build/adb-native/libusb-1.0.30/COPYING', notices / 'libusb-LGPL-2.1.txt')
    packages['googletest-headers'] = Path('/opt/homebrew/opt/googletest').resolve()
    for name, package in packages.items():
        target = notices / name
        target.mkdir(exist_ok=True)
        licenses = [p for p in package.rglob('*') if p.is_file() and
                    p.name.lower().startswith(('license', 'copying', 'notice', 'authors'))]
        if not licenses:
            raise SystemExit('Missing dependency notices: ' + name)
        for path in licenses:
            dest = target / path.relative_to(package)
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(path, dest)
        for name in ('sbom.spdx.json', 'INSTALL_RECEIPT.json'):
            if (package / name).exists():
                shutil.copy2(package / name, target / name)
    extra = ROOT / 'ThirdParty/AndroidTools'
    if not extra.exists():
        extra = ROOT
    shutil.copy2(extra / 'utf8_range-LICENSE', notices / 'utf8_range-LICENSE')
    shutil.copy2(__file__, notices / 'adb-build.py')
    (notices / 'SOURCE.json').write_text(json.dumps({
        'version': '37.0.0p1', 'source': ARCHIVES,
        'changes': 'Homebrew header order; mDNS disabled; shared replaceable libusb; paths rewritten; local code signing',
        'libraries': {name: str(path) for name, path in copied.items()},
    }, indent=2) + '\n')


if __name__ == '__main__':
    prepare(Path(sys.argv[1]).resolve())
