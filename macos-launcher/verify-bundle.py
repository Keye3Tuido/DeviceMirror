#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
"""Check the distributable without opening a GUI or changing desktop focus."""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import socket
import subprocess
import sys
import tempfile
import time

def verify_adb_startup(adb, directory, env):
    # A private port forces a fresh server, independent of Android Studio/adb.
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    log = Path(directory) / 'adb-startup.log'
    with log.open('w') as output:
        server = subprocess.Popen([str(adb), '-L', f'tcp:{port}', 'nodaemon', 'server'],
                                  cwd=directory, env=env, stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 15
            while time.monotonic() < deadline:
                assert server.poll() is None, f'adb server exited ({server.returncode}): {log.read_text()}'
                try:
                    with socket.create_connection(('127.0.0.1', port), timeout=0.25) as connection:
                        connection.sendall(b'000chost:version')
                        response = b''
                        while len(response) < 4:
                            data = connection.recv(4 - len(response))
                            if not data:
                                break
                            response += data
                        if response == b'OKAY':
                            break
                except OSError:
                    pass
                time.sleep(0.05)
            else:
                raise AssertionError(f'adb startup timed out: {log.read_text()}')
            result = subprocess.run([str(adb), '-H', '127.0.0.1', '-P', str(port), 'devices', '-l'],
                                    cwd=directory, env=env, capture_output=True, text=True, timeout=10, check=True)
            assert 'List of devices attached' in result.stdout, result.stdout + result.stderr
        finally:
            if server.poll() is None:
                server.terminate()
                try:
                    server.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    server.kill()
                    server.wait()


app = Path(sys.argv[1]).resolve()
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleExecutable'] == 'DeviceMirror'
assert 'NSBluetoothAlwaysUsageDescription' not in info
assert (app / 'Contents/Resources/AndroidInput/device-mirror-input.apk').is_file()
assert (app / 'Contents/Helpers/android-input').is_file()
assert (app / 'Contents/Helpers/ios-input').is_file()
assert not list(app.rglob('*.app')), 'Unexpected nested app entry'
assert not list(app.rglob('ios_bridge.py')) and not list(app.rglob('idevice_tools'))
binaries = [app / 'Contents/MacOS/DeviceMirror', *list((app / 'Contents/Helpers').iterdir()), *list((app / 'Contents/Frameworks').glob('*.dylib'))]
def os_version(value):
    parts = tuple(int(part) for part in value.split('.'))
    return parts + (0,) * (3 - len(parts))


for binary in binaries:
    architectures = subprocess.check_output(['/usr/bin/lipo', '-archs', str(binary)], text=True).split()
    assert 'arm64' in architectures, (binary, architectures)
    commands = subprocess.check_output(['/usr/bin/otool', '-l', str(binary)], text=True)
    deployment = re.search(r'\bminos (\d+(?:\.\d+)*)', commands)
    if deployment is None:
        deployment = re.search(r'LC_VERSION_MIN_MACOSX\s+cmdsize \d+\s+version (\d+(?:\.\d+)*)', commands)
    assert deployment and os_version(deployment.group(1)) <= os_version(info['LSMinimumSystemVersion']), (binary, 'incompatible deployment target')
    links = subprocess.check_output(['/usr/bin/otool', '-L', str(binary)], text=True).splitlines()[1:]
    for line in links:
        dependency = line.strip().split(' (', 1)[0]
        if dependency.startswith(('/usr/lib/', '/System/Library/')):
            continue
        assert dependency.startswith('@loader_path/'), (binary, dependency)
        assert (binary.parent / dependency.removeprefix('@loader_path/')).is_file(), (binary, dependency)
third_party = app / 'Contents/Resources/ThirdParty'
assert (third_party / 'Android-tools/libusb-1.0.30.tar.bz2').is_file()
assert (third_party / 'Android-tools/android-tools-37.0.0p1.tar.xz').is_file()
assert (third_party / 'Android-tools/utf8_range-LICENSE').is_file()
assert (third_party / 'Sources/ffmpeg-n9.0.2.tar.gz').is_file()
for name in ('ipb-MIT.txt', 'idb-MIT.txt', 'README.md'):
    assert (third_party / 'ios-control' / name).is_file()
# Launch helpers from a copied app, with no SDK, Homebrew or Python in PATH.
# The native main executable is deliberately not started: it would open a window.
with tempfile.TemporaryDirectory(prefix='DeviceMirror-portable-') as directory:
    relocated = Path(directory) / 'Moved Device Mirror.app'
    shutil.copytree(app, relocated)
    # Installed apps can be read-only and have spaces in every parent path.
    modes = {path: path.stat().st_mode & 0o777 for path in [relocated, *relocated.rglob('*')]}
    try:
        for path, mode in modes.items():
            path.chmod(mode & ~0o222)
        env = {key: value for key, value in os.environ.items() if key in ('HOME', 'USER', 'TMPDIR', 'LANG', 'LOGNAME')}
        env['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
        verify_adb_startup(relocated / 'Contents/Helpers/adb', directory, env)
        env['SCRCPY_SERVER_PATH'] = str(relocated / 'Contents/Resources/scrcpy/scrcpy-server')
        for name, args in [('adb', ['version']), ('scrcpy', ['--version']), ('device-service', ['--list']), ('ios-input', ['--version'])]:
            result = subprocess.run([str(relocated / 'Contents/Helpers' / name), *args], cwd=directory, env=env, capture_output=True, text=True, timeout=30, check=True)
            if name == 'device-service':
                assert isinstance(json.loads(result.stdout)['devices'], list)
        no_xcode = dict(env, DEVELOPER_DIR='/DeviceMirror-missing-Xcode')
        listing = subprocess.run([str(relocated / 'Contents/Helpers/device-service'), '--list'],
                                 cwd=directory, env=no_xcode, capture_output=True, text=True, timeout=30, check=True)
        assert isinstance(json.loads(listing.stdout)['devices'], list)
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(relocated)], check=True)
    finally:
        for path, mode in modes.items():
            path.chmod(mode)
print(f'PASS: arm64/deployment targets; one app entry; {len(binaries)} native binaries; local dylibs; licenses/source; fresh adb server; read-only bundle; missing Xcode enumeration; relocated helpers without SDK/Python/Homebrew PATH; signatures')
