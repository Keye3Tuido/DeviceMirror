#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
"""Check bottom-edge Home swipes using an exclusively owned WDA service.

Pass its connection JSON. The check restarts the selected app, tests Home in
portrait and landscape, then restores rotation. No Mac window is opened.
"""
from ios_live_client import LiveInput
import argparse
import json
from pathlib import Path
import time
import urllib.request
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('connection', type=Path)
    parser.add_argument('--app', default='com.apple.Preferences', help='Installed app to restart for each check')
    args = parser.parse_args()
    port = json.loads(args.connection.read_text())['httpPort']
    base = f'http://127.0.0.1:{port}'
    http = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    def request(path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(base + path, data=data, headers={'Content-Type': 'application/json'})
        with http.open(req, timeout=25) as response:
            result = json.load(response)
        value = result.get('value')
        assert not isinstance(value, dict) or 'error' not in value, value
        return result

    assert not request('/wda/locked')['value'], 'Unlock the device before testing'
    session = request('/session', {'capabilities': {'alwaysMatch': {'shouldWaitForQuiescence': False}}})
    prefix = '/session/' + session['sessionId']

    live = LiveInput(args.connection, request, prefix)

    def settings(**values):
        request(prefix + '/appium/settings', {'settings': values})

    def source():
        settings(defaultActiveApplication='com.apple.springboard')
        return ET.fromstring(request(prefix + '/source?format=xml')['value'])

    def icons(root):
        return [e for e in root.iter('XCUIElementTypeIcon') if e.get('visible') == 'true']

    def overview_visible(root):
        # iPadOS can leave a dock-sized card marked visible inside the hidden
        # App Switcher container. Its ancestors determine actual visibility.
        parents = {child: parent for parent in root.iter() for child in parent}
        for element in root.iter():
            if not element.get('name', '').startswith('card:'):
                continue
            current = element
            while current is not None and current.get('visible') != 'false':
                current = parents.get(current)
            if current is None:
                return True
        return False

    def home():
        started = time.monotonic()
        live.key('home')
        print(f'Home bottom-edge swipe: {(time.monotonic() - started) * 1000:.0f} ms', flush=True)
        time.sleep(0.6)

    settings(waitForIdleTimeout=0, animationCoolOffTimeout=0)
    original_rotation = request(prefix + '/rotation')['value']
    try:
        for orientation in ['PORTRAIT', 'LANDSCAPE']:
            request(prefix + '/orientation', {'orientation': orientation})
            for active in ['auto', args.app]:
                settings(defaultActiveApplication='auto')
                request(prefix + '/wda/apps/terminate', {'bundleId': args.app})
                request(prefix + '/wda/apps/launch', {'bundleId': args.app})
                time.sleep(0.5)
                before = len(icons(source()))
                settings(defaultActiveApplication=active)
                home()
                deadline = time.monotonic() + 5
                while True:
                    root = source()
                    if len(icons(root)) > before and not overview_visible(root):
                        break
                    assert time.monotonic() < deadline, 'Home must reveal desktop icons and leave App Switcher'
                    time.sleep(0.15)
                print(f'PASS: {orientation}, active application={active}, Home icons visible', flush=True)
            live.key('appSwitcher')
            time.sleep(0.6)
            assert overview_visible(source()), 'The check must also recognize the real App Switcher'
            settings(defaultActiveApplication='auto')
            home()
            assert not overview_visible(source()), 'A Home swipe must leave App Switcher'
    finally:
        live.close()
        request(prefix + '/rotation', original_rotation)
        settings(defaultActiveApplication='auto')


if __name__ == '__main__':
    main()
