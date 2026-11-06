#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
"""Check real Back and touch delivery on an exclusively owned simulator WDA service.

Builds/installs the test-only fixture and removes it on exit. Opens no Mac window.
Usage: verify_ios_controls.py connection.json simulator-udid evidence-directory
"""
import argparse
import base64
import json
import os
from pathlib import Path
import plistlib
import subprocess
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('connection', type=Path)
    parser.add_argument('simulator')
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    base = 'http://127.0.0.1:' + str(json.loads(args.connection.read_text())['httpPort'])
    http = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    bundle = 'com.keye3tuido.DeviceMirror.NavigationProbe'
    env = {k: v for k, v in os.environ.items() if k not in ['SDKROOT', 'CPATH', 'LIBRARY_PATH', 'MACOSX_DEPLOYMENT_TARGET', 'LDFLAGS', 'CFLAGS', 'CXXFLAGS']}

    def run(*command):
        return subprocess.check_output(command, env=env, text=True).strip()

    app = args.output / 'Probe.app'
    app.mkdir(exist_ok=True)
    sdk = run('xcrun', '--sdk', 'iphonesimulator', '--show-sdk-path')
    run('xcrun', 'swiftc', '-sdk', sdk, '-target', 'arm64-apple-ios26.0-simulator',
        str(Path(__file__).parent / 'fixtures/IOSControlProbe.swift'), '-o', str(app / 'Probe'))
    (app / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': bundle, 'CFBundleName': 'Control Probe',
        'CFBundleExecutable': 'Probe', 'CFBundlePackageType': 'APPL', 'CFBundleVersion': '1',
        'CFBundleShortVersionString': '1.0', 'UILaunchScreen': {}, 'LSRequiresIPhoneOS': True,
        'UIDeviceFamily': [1, 2], 'UISupportedInterfaceOrientations': ['UIInterfaceOrientationPortrait',
            'UIInterfaceOrientationLandscapeLeft', 'UIInterfaceOrientationLandscapeRight']}))
    run('codesign', '--force', '--sign', '-', str(app))

    def request(path, body=None, expected=200):
        req = urllib.request.Request(base + path, data=None if body is None else json.dumps(body).encode(),
                                     headers={'Content-Type': 'application/json'})
        try:
            with http.open(req, timeout=45) as reply:
                status, value = reply.status, json.load(reply)
        except urllib.error.HTTPError as error:
            status, value = error.code, json.load(error)
        assert status == expected, value
        return value

    session = request('/session', {'capabilities': {'alwaysMatch': {'shouldWaitForQuiescence': False}}})
    prefix = '/session/' + session['sessionId']
    request(prefix + '/appium/settings', {'settings': {'waitForIdleTimeout': 0, 'animationCoolOffTimeout': 0,
                                                     'defaultActiveApplication': bundle}})

    def source():
        return ET.fromstring(request(prefix + '/source?format=xml')['value'])

    def find(name):
        return next(e for e in source().iter() if e.get('name') == name and e.get('visible') == 'true')

    def tap(name):
        element = request(prefix + '/element', {'using': 'accessibility id', 'value': name})['value']
        identifier = element['ELEMENT']
        request(prefix + '/element/' + identifier + '/click', {})

    def launch():
        run('xcrun', 'simctl', 'terminate', args.simulator, bundle)
        run('xcrun', 'simctl', 'launch', args.simulator, bundle)
        time.sleep(0.4)

    def back(method=None, expected=200, duration=0):
        started = time.monotonic()
        reply = request(prefix + '/wda/devicemirror/navigation', {'action': 'back', 'duration': duration}, expected)
        if method: assert reply['value']['method'] == method, reply
        print('Back', method or 'unavailable', round((time.monotonic() - started) * 1000), 'ms', flush=True)

    def screenshot(name):
        (args.output / (name + '.png')).write_bytes(base64.b64decode(request('/screenshot')['value']))

    def touch(path):
        area = find('touch-area')
        root = source()
        points = [{'x': (float(area.get('x')) + x * float(area.get('width'))) / float(root.get('width')),
                   'y': (float(area.get('y')) + y * float(area.get('height'))) / float(root.get('height')),
                   'time': t} for x, y, t in path]
        request(prefix + '/wda/devicemirror/gesture', {'points': points})
        actual = json.loads(find('touch-result').get('label'))
        for index in [0, -1]:
            assert abs(actual[index][0] - path[index][0]) < 0.03, (path, actual)
            assert abs(actual[index][1] - path[index][1]) < 0.03, (path, actual)
        assert abs(actual[-1][2] - path[-1][2]) < 0.15, actual
        return actual

    try:
        run('xcrun', 'simctl', 'install', args.simulator, str(app))
        run('xcrun', 'simctl', 'launch', args.simulator, bundle)
        request(prefix + '/orientation', {'orientation': 'PORTRAIT'})
        tap('standard'); back('navigationButton'); find('standard')
        back(expected=500)
        assert any(e.get('name') == 'Root' for e in source().iter('XCUIElementTypeNavigationBar')), 'Root Back must not trigger Compose'
        tap('custom'); back('labeledBackButton'); find('custom'); screenshot('custom-back')
        tap('custom'); back('labeledBackButton', duration=0.8)
        assert find('long-back-result').get('label') == 'Held Back', 'Held Back must trigger the control long-press recognizer'
        back('labeledBackButton'); find('custom')
        back(expected=500, duration=-1)
        back(expected=500, duration=31)
        tap('web'); time.sleep(3)
        (args.output / 'before-web-back.xml').write_text(ET.tostring(source(), encoding='unicode'))
        back('labeledBackButton'); find('First page'); screenshot('web-back')
        launch(); tap('scroll')
        def rows():
            return [e.get('name') for e in source().iter('XCUIElementTypeStaticText') if e.get('visible') == 'true' and e.get('name', '').startswith('Row ')]
        before = rows()
        request(prefix + '/wda/devicemirror/gesture', {'points': [{'x': 0.5, 'y': 0.8, 'time': 0}, {'x': 0.5, 'y': 0.3, 'time': 0.4}]})
        assert rows() != before, 'Touch path must scroll actual UIKit content'
        screenshot('scroll')
        launch(); tap('touch')
        actual = touch([(0.2, 0.7, 0), (0.5, 0.3, 0.3), (0.8, 0.6, 0.6), (0.8, 0.6, 1.1)])
        assert any(abs(p[0] - 0.5) < 0.05 and abs(p[1] - 0.3) < 0.05 for p in actual), actual
        assert max(p[2] for p in actual if abs(p[0] - 0.8) < 0.03) - min(p[2] for p in actual if abs(p[0] - 0.8) < 0.03) >= 0.4
        touch([(0.5, 0.5, 0), (0.5, 0.5, 0.8)])
        screenshot('portrait-touch')
        request(prefix + '/orientation', {'orientation': 'LANDSCAPE'})
        time.sleep(0.5)
        touch([(0.2, 0.3, 0), (0.8, 0.7, 0.4)])
        for _ in range(2):
            current = request(prefix + '/orientation')['value']
            target = 'LANDSCAPE' if current == 'PORTRAIT' else 'PORTRAIT'
            request(prefix + '/orientation', {'orientation': target})
            assert request(prefix + '/orientation')['value'] == target
            time.sleep(0.5)
            touch([(0.5, 0.5, 0), (0.5, 0.5, 0.8)])
        screenshot('landscape-touch')
        for points in [[], [{'x': 0, 'y': 0, 'time': 0}],
                       [{'x': 0, 'y': 0, 'time': 0}, {'x': 2, 'y': 0, 'time': 1}],
                       [{'x': 0, 'y': 0, 'time': 0}, {'x': 0, 'y': 0, 'time': -1}]]:
            request(prefix + '/wda/devicemirror/gesture', {'points': points}, expected=500)
        print('PASS: standard/custom/web Back; held Back; root safety; UIKit scrolling; curved touch path, hold, long press; rotation toggle and rotated touch; invalid input.', flush=True)
    finally:
        try:
            request(prefix + '/orientation', {'orientation': 'PORTRAIT'})
        finally:
            run('xcrun', 'simctl', 'uninstall', args.simulator, bundle)


if __name__ == '__main__':
    main()
