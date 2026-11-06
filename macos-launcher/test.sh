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
xcrun swiftc -swift-version 5 Sources/DeviceKeyButton.swift tests/KeyButtonTests.swift -o .build/key-button-tests
.build/key-button-tests
xcrun swiftc -swift-version 5 Sources/AndroidCore.swift Sources/USBMux.swift DeviceService/ServiceSupport.swift DeviceService/USBForwarder.swift tests/ServiceTests.swift -o .build/service-tests
.build/service-tests
xcrun cc -std=c11 -Wall -Wextra tests/EdgeGeometryTests.c -o .build/edge-tests
.build/edge-tests
xcrun clang -fobjc-arc -I../app/src -I.build/scrcpy/app -I.build/ffmpeg-install/include \
    -I/opt/homebrew/include tests/AndroidToolbarTests.m -framework AppKit \
    -L/opt/homebrew/lib -lSDL3 -o .build/toolbar-tests
.build/toolbar-tests
xcrun cc -I../app/src -I.build/scrcpy/app -I/opt/homebrew/include \
    tests/AndroidInputQueueTests.c ../app/src/controller.c ../app/src/control_msg.c \
    ../app/src/util/thread.c ../app/src/util/str.c ../app/src/util/strbuf.c \
    ../app/src/util/memory.c ../app/src/util/tick.c ../app/src/compat.c \
    -L/opt/homebrew/lib -lSDL3 -o .build/input-queue-tests
.build/input-queue-tests
xcrun cc -DSC_TEST -I../app/src -I.build/scrcpy/app -I/opt/homebrew/include \
    ../app/tests/test_control_msg_serialize.c ../app/src/control_msg.c ../app/src/util/str.c \
    ../app/src/util/strbuf.c ../app/src/compat.c -L/opt/homebrew/lib -lSDL3 -o .build/control-msg-tests
.build/control-msg-tests
xcrun swiftc -swift-version 5 Sources/AndroidCore.swift AndroidInputService/main.swift -o .build/android-input-tests-service
/usr/bin/python3 -m unittest discover -s tests -p 'test_*.py' -v
