#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
"""Verify navigation against an exclusively owned WDA service, without opening a Mac window.

Start the device on a page with a standard navigation Back button. This check
navigates back from that page, opens Home and opens the App Switcher.
Pass the device-service connection JSON and a directory for screenshot evidence.
"""
import argparse
import base64
import json
from pathlib import Path
import time
import urllib.request
import xml.etree.ElementTree as ET


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('connection', type=Path)
    parser.add_argument('output', type=Path)
    args = parser.parse_args()
    port = json.loads(args.connection.read_text())['httpPort']
    base = f'http://127.0.0.1:{port}'
    args.output.mkdir(parents=True, exist_ok=True)

    def request(path, body=None):
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(base + path, data=data,
                                     headers={'Content-Type': 'application/json'})
        with urllib.request.urlopen(req, timeout=15) as reply:
            value = json.load(reply)
        assert not isinstance(value.get('value'), dict) or 'error' not in value['value'], value
        return value

    session = request('/session', {'capabilities': {'alwaysMatch': {'shouldWaitForQuiescence': False}}})
    prefix = '/session/' + session['sessionId']
    request(prefix + '/appium/settings', {'settings': {'waitForIdleTimeout': 0, 'animationCoolOffTimeout': 0}})

    def source():
        return ET.fromstring(request(prefix + '/source?format=xml')['value'])

    def screenshot(name):
        (args.output / (name + '.png')).write_bytes(base64.b64decode(request('/screenshot')['value']))

    def titles(root):
        return [e.get('name') for e in root.iter('XCUIElementTypeNavigationBar') if e.get('visible') == 'true']

    def navigation(action):
        started = time.monotonic()
        request(prefix + '/wda/devicemirror/navigation', {'action': action})
        print(f'{action}: {(time.monotonic() - started) * 1000:.0f} ms', flush=True)
        time.sleep(0.6)

    before = source()
    assert any(e.get('visible') == 'true' and
               (e.get('name') == 'BackButton' or 'BackButton' in e.get('traits', ''))
               for e in before.iter('XCUIElementTypeButton')), 'Open a detail page with a standard Back button before running this check'
    screenshot('before-back')
    navigation('back')
    assert titles(source()) != titles(before), 'Back acknowledged but navigation title did not change'
    screenshot('after-back')

    navigation('home')
    request(prefix + '/appium/settings', {'settings': {'defaultActiveApplication': 'com.apple.springboard'}})
    try:
        home = source()
        assert any(e.get('visible') == 'true' for e in home.iter('XCUIElementTypeIcon')), 'Home acknowledged but no home icons visible'
        screenshot('home')
        navigation('appSwitcher')
        switcher = source()
        width, height = float(switcher.get('width')), float(switcher.get('height'))
        assert any(e.get('visible') == 'true' and e.get('name', '').startswith('card:')
                   and 50 < float(e.get('width', 0)) < width * 0.95
                   and 50 < float(e.get('height', 0)) < height * 0.95
                   for e in switcher.iter()), 'App Switcher acknowledged but no overview card visible'
        screenshot('app-switcher')
    finally:
        request(prefix + '/appium/settings', {'settings': {'defaultActiveApplication': 'auto'}})
    print('PASS: Back changes page; Home shows icons; App Switcher shows an overview card.', flush=True)


if __name__ == '__main__':
    main()
