#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
"""Check the distributable without opening a GUI or changing desktop focus."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile

app = Path(sys.argv[1]).resolve()
subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
assert info['CFBundleExecutable'] == 'DeviceMirror'
assert 'NSBluetoothAlwaysUsageDescription' not in info
assert (app / 'Contents/Resources/AndroidInput/device-mirror-input.apk').is_file()
assert (app / 'Contents/Helpers/android-input').is_file()
assert not list(app.rglob('*.app')), 'Unexpected nested app entry'
assert not list(app.rglob('ios_bridge.py')) and not list(app.rglob('idevice_tools'))
binaries = [app / 'Contents/MacOS/DeviceMirror', *list((app / 'Contents/Helpers').iterdir()), *list((app / 'Contents/Frameworks').glob('*.dylib'))]
for binary in binaries:
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
# Launch helpers from a copied app, with no SDK, Homebrew or Python in PATH.
# The native main executable is deliberately not started: it would open a window.
with tempfile.TemporaryDirectory(prefix='DeviceMirror-portable-') as directory:
    relocated = Path(directory) / 'Moved Device Mirror.app'
    shutil.copytree(app, relocated)
    env = {key: value for key, value in os.environ.items() if key in ('HOME', 'USER', 'TMPDIR', 'LANG', 'LOGNAME')}
    env['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
    env['SCRCPY_SERVER_PATH'] = str(relocated / 'Contents/Resources/scrcpy/scrcpy-server')
    for name, args in [('adb', ['version']), ('scrcpy', ['--version']), ('device-service', ['--list'])]:
        result = subprocess.run([str(relocated / 'Contents/Helpers' / name), *args], cwd=directory, env=env, capture_output=True, text=True, timeout=30, check=True)
        if name == 'device-service':
            assert isinstance(json.loads(result.stdout)['devices'], list)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(relocated)], check=True)
print(f'PASS: one app entry; {len(binaries)} native binaries; local dylibs; licenses/source; relocated helpers without SDK/Python/Homebrew PATH; signatures')
