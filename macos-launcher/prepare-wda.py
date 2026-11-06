#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
"""Add Device Mirror touch and navigation endpoints to the packaged WDA source, retaining upstream notices."""
import hashlib
from pathlib import Path
import shutil
import subprocess
import sys


def prepare(source, bundle, extension):
    shutil.copytree(source, bundle, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns('.git', 'node_modules', '__pycache__'))
    target = bundle / 'WebDriverAgentLib/Commands/FBTouchActionCommands.m'
    marker = '\n// Device Mirror addition: touch and navigation endpoints (Apache-2.0).\n#import "DMControlCommands.m"\n'
    # The vendor checkout remains unchanged. This generated source has only the
    # explicit import below, plus our separately licensed implementation.
    target.write_bytes((source / target.relative_to(bundle)).read_bytes() + marker.encode())
    shutil.copy2(extension, target.with_name(extension.name))
    shutil.copy2(Path(__file__).resolve().parent.parent / 'LICENSE', bundle / 'DEVICE_MIRROR_LICENSE')
    revision = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    digest = hashlib.sha256(extension.read_bytes() + Path(__file__).read_bytes()).hexdigest()
    (bundle / 'DEVICE_MIRROR_VERSION').write_text(revision + '\nDeviceMirror-control-' + digest + '\n')


if __name__ == '__main__':
    prepare(*(Path(p).resolve() for p in sys.argv[1:]))
