#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
"""Build our activity-free IME with Android SDK tools; no downloaded source."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

root = Path(__file__).resolve().parent
sdk = Path(os.environ.get('ANDROID_HOME', Path.home() / 'Library/Android/sdk'))
java = Path(os.environ.get('JAVA_HOME', '/Applications/Android Studio.app/Contents/jbr/Contents/Home'))
tools = sdk / 'build-tools/36.1.0'
android = sdk / 'platforms/android-36/android.jar'
env = dict(os.environ, JAVA_HOME=str(java), PATH=str(java / 'bin') + os.pathsep + os.environ.get('PATH', ''))
build = root / '.build/android-input'
build.mkdir(parents=True, exist_ok=True)
classes = build / 'classes'
shutil.rmtree(classes, ignore_errors=True)
classes.mkdir()

def run(*args):
    subprocess.run([str(arg) for arg in args], check=True, env=env)

run(java / 'bin/javac', '-source', '8', '-target', '8', '-bootclasspath', android, '-d', classes,
    *sorted((root / 'AndroidInput/src').rglob('*.java')))
run(tools / 'd8', '--min-api', '21', '--lib', android, '--output', build, *sorted(classes.rglob('*.class')))
resources = build / 'resources.zip'
run(tools / 'aapt2', 'compile', '--dir', root / 'AndroidInput/res', '-o', resources)
unsigned = build / 'unsigned.apk'
run(tools / 'aapt2', 'link', '-o', unsigned, '--manifest', root / 'AndroidInput/AndroidManifest.xml', '-I', android, resources)
with zipfile.ZipFile(unsigned, 'a') as apk:
    apk.write(build / 'classes.dex', 'classes.dex')
aligned = build / 'aligned.apk'
run(tools / 'zipalign', '-f', '4', unsigned, aligned)
# Keep a stable local signing identity across rebuilds. The keystore stays in
# the ignored build cache and is not part of the distributed Mac app.
key = build / 'input.keystore'
if not key.exists():
    run(java / 'bin/keytool', '-genkeypair', '-keystore', key, '-storepass', 'android', '-keypass', 'android',
        '-alias', 'input', '-keyalg', 'RSA', '-keysize', '2048', '-validity', '10000', '-dname', 'CN=Device Mirror Input')
output = Path(sys.argv[1]) if len(sys.argv) > 1 else build / 'device-mirror-input.apk'
output.parent.mkdir(parents=True, exist_ok=True)
run(tools / 'apksigner', 'sign', '--ks', key, '--ks-key-alias', 'input', '--ks-pass', 'pass:android', '--out', output, aligned)
run(tools / 'apksigner', 'verify', output)
print(output)
