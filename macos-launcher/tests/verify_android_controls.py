#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
"""Install a temporary input probe and verify packaged Android control events.

Pass the app and an authorized device serial. Uses no Mac windows. Uninstalls
its probe, removes its forwarding rule and server file on exit.
"""
import argparse
import os
from pathlib import Path
import re
import secrets
import socket
import struct
import subprocess
import tempfile
import time
import zipfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('serial')
    args = parser.parse_args()
    app = args.app.resolve()
    adb = [str(app / 'Contents/Helpers/adb'), '-s', args.serial]
    bundle = 'com.keye3tuido.devicemirror.probe'
    sdk = Path(os.environ.get('ANDROID_HOME', Path.home() / 'Library/Android/sdk'))
    java = Path(os.environ.get('JAVA_HOME', '/Applications/Android Studio.app/Contents/jbr/Contents/Home'))
    tools = sdk / 'build-tools/36.1.0'
    android = sdk / 'platforms/android-36/android.jar'
    env = dict(os.environ, JAVA_HOME=str(java), PATH=str(java / 'bin') + os.pathsep + os.environ.get('PATH', ''))

    def run(*command, check=True):
        result = subprocess.run([str(x) for x in command], env=env, capture_output=True, text=True)
        if check and result.returncode:
            raise RuntimeError(result.stderr or result.stdout)
        return result.stdout.strip()

    def device(*command, check=True):
        return run(*adb, *command, check=check)

    def events():
        return device('shell', 'run-as', bundle, 'cat', 'files/events.txt').splitlines()

    def wait_for(check):
        deadline = time.monotonic() + 8
        while not check():
            assert time.monotonic() < deadline, 'Device did not report expected control event'
            time.sleep(0.1)

    scid = secrets.randbelow(0x7ffffffe) + 1
    remote = f'/data/local/tmp/dm-control-probe-{scid}.jar'
    server = None
    control = None
    port = None
    original_auto = device('shell', 'settings', 'get', 'system', 'accelerometer_rotation')
    original_rotation = device('shell', 'settings', 'get', 'system', 'user_rotation')
    with tempfile.TemporaryDirectory(prefix='dm-android-probe-') as temporary:
        build = Path(temporary)
        classes = build / 'classes'; classes.mkdir()
        run(java / 'bin/javac', '-source', '8', '-target', '8', '-bootclasspath', android,
            '-cp', tools / 'core-lambda-stubs.jar', '-d', classes,
            Path(__file__).parent / 'fixtures/AndroidControlsProbe.java')
        run(tools / 'd8', '--min-api', '21', '--lib', android, '--output', build, *classes.rglob('*.class'))
        manifest = build / 'AndroidManifest.xml'
        manifest.write_text(f'''<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="{bundle}">
<uses-sdk android:minSdkVersion="21" android:targetSdkVersion="36"/>
<application android:debuggable="true" android:theme="@android:style/Theme.Material.Light.NoActionBar" android:label="Device Mirror Control Probe">
<activity android:name=".AndroidControlsProbe" android:exported="true" android:configChanges="orientation|screenSize"/></application></manifest>''')
        unsigned = build / 'unsigned.apk'
        run(tools / 'aapt2', 'link', '-o', unsigned, '--manifest', manifest, '-I', android)
        with zipfile.ZipFile(unsigned, 'a') as apk:
            apk.write(build / 'classes.dex', 'classes.dex')
        aligned = build / 'aligned.apk'
        run(tools / 'zipalign', '-f', '4', unsigned, aligned)
        key = build / 'probe.keystore'
        run(java / 'bin/keytool', '-genkeypair', '-keystore', key, '-storepass', 'android', '-keypass', 'android',
            '-alias', 'probe', '-keyalg', 'RSA', '-validity', '1', '-dname', 'CN=Temporary Device Mirror Test')
        apk = build / 'probe.apk'
        run(tools / 'apksigner', 'sign', '--ks', key, '--ks-key-alias', 'probe', '--ks-pass', 'pass:android', '--out', apk, aligned)
        try:
            result = device('install', '-r', apk)
            assert 'Success' in result, result
            device('shell', 'am', 'start', '-W', '-n', bundle + '/.AndroidControlsProbe')
            wait_for(lambda: any(line.startswith('ORIENTATION') for line in events()))
            original = events()[-1]
            device('push', app / 'Contents/Resources/scrcpy/scrcpy-server', remote)
            port = device('forward', 'tcp:0', f'localabstract:scrcpy_{scid:08x}')
            log = open(build / 'server.log', 'w')
            server = subprocess.Popen([*adb, 'shell', f'CLASSPATH={remote}', 'app_process', '/', 'com.genymobile.scrcpy.Server',
                '5.0.1', f'scid={scid:x}', 'tunnel_forward=true', 'video=false', 'audio=false', 'control=true',
                'send_dummy_byte=false', 'send_device_meta=false', 'clipboard_autosync=false'], stdout=log, stderr=log)
            time.sleep(0.8)
            control = socket.create_connection(('127.0.0.1', int(port)), timeout=5)
            wait_for(lambda: re.search(r'mCurrentFocus=.*' + re.escape(bundle), device('shell', 'dumpsys', 'window')))
            time.sleep(0.6)
            def key(action, repeat=0):
                control.sendall(struct.pack('>BBIII', 0, action, 24, repeat, 0))
            key(0); time.sleep(0.55); key(0, 1); time.sleep(0.1); key(0, 2); time.sleep(0.1); key(1)
            wait_for(lambda: len([x for x in events() if x.startswith('KEY')]) >= 4)
            received = [list(map(int, line.split()[1:])) for line in events() if line.startswith('KEY')]
            assert [x[:2] for x in received] == [[0, 0], [0, 1], [0, 2], [1, 0]], received
            assert received[1][2] & 0x80 and not received[0][2] & 0x80, received
            assert len({x[3] for x in received}) == 1 and received[-1][4] - received[0][3] >= 700, received
            print('PASS: Android held key DOWN/repeat/LONG_PRESS/UP; original down time retained', flush=True)
            # The actual service rotates the interface; no local image transform is used.
            for _ in range(2):
                before = len([x for x in events() if x.startswith('ORIENTATION')])
                control.sendall(bytes([11]))
                wait_for(lambda: len([x for x in events() if x.startswith('ORIENTATION')]) > before)
                time.sleep(0.5)
            assert [x for x in events() if x.startswith('ORIENTATION')][-1] == original
            dimensions = device('shell', 'wm', 'size')
            width, height = map(int, re.findall(r'(\d+)x(\d+)', dimensions)[-1])
            if original.endswith('2'): width, height = max(width, height), min(width, height)
            else: width, height = min(width, height), max(width, height)
            def touch(action):
                control.sendall(struct.pack('>BBQiiHHHII', 2, action, 0xffffffffffffffff,
                    width // 2, height // 2, width, height, 0xffff if action == 0 else 0, 0, 0))
            touch(0); time.sleep(0.9); touch(1)
            wait_for(lambda: 'LONG_TOUCH' in events())
            assert 'SHORT_TOUCH' not in events(), events()
            print('PASS: Android rotation toggles twice and touch triggers long press without a short click', flush=True)
        except Exception:
            try: print('Probe events:', events(), flush=True)
            except RuntimeError: pass
            if server: print((build / 'server.log').read_text(), flush=True)
            raise
        finally:
            if control: control.close()
            if server:
                try: server.wait(timeout=8)
                except subprocess.TimeoutExpired: server.terminate(); server.wait(timeout=5)
            if port: device('forward', '--remove', 'tcp:' + port, check=False)
            device('shell', 'rm', '-f', remote, check=False)
            device('uninstall', bundle, check=False)
            for name, value in [('user_rotation', original_rotation), ('accelerometer_rotation', original_auto)]:
                if value != 'null': device('shell', 'settings', 'put', 'system', name, value, check=False)


if __name__ == '__main__':
    main()
