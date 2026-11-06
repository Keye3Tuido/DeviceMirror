#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build
xcrun swiftc -swift-version 5 Sources/AndroidCore.swift Sources/AndroidLog.swift Sources/MirrorGeometry.swift Sources/MJPEGParser.swift Sources/USBMux.swift tests/CoreTests.swift tests/MirrorFeatureTests.swift -o .build/core-tests
.build/core-tests
xcrun swiftc -swift-version 5 Sources/MirrorGeometry.swift Sources/IOSCanvasView.swift tests/CanvasTests.swift -o .build/canvas-tests
.build/canvas-tests
xcrun swiftc -swift-version 5 Sources/AndroidCore.swift Sources/USBMux.swift DeviceService/ServiceSupport.swift DeviceService/USBForwarder.swift tests/ServiceTests.swift -o .build/service-tests
.build/service-tests
xcrun cc -std=c11 -Wall -Wextra tests/EdgeGeometryTests.c -o .build/edge-tests
.build/edge-tests
xcrun clang -fobjc-arc -I../app/src -I.build/scrcpy/app -I.build/ffmpeg-install/include \
    -I/opt/homebrew/include tests/AndroidToolbarTests.m -framework AppKit \
    -L/opt/homebrew/lib -lSDL3 -o .build/toolbar-tests
.build/toolbar-tests
/usr/bin/python3 -m unittest discover -s tests -p 'test_*.py' -v
