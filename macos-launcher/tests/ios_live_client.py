# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
"""Device-facing test client for the app's native input helper (iOS27+ only)."""
import json
from pathlib import Path
import selectors
import subprocess
import time


class LiveInput:
    def __init__(self, connection, request, prefix):
        value = json.loads(Path(connection).read_text())
        self.request, self.prefix = request, prefix
        helper = Path(__file__).resolve().parents[2] / 'Device Mirror.app/Contents/Helpers/ios-input'
        self.process = subprocess.Popen([str(helper), '--udid', value['udid'], '--kind', value['kind']],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(self.process.stdout, selectors.EVENT_READ)
                if not selector.select(80):
                    raise RuntimeError('Native input startup timed out')
                reply = json.loads(self.process.stdout.readline())
                if reply.get('ready') is not True:
                    raise RuntimeError(reply)
        except BaseException:
            self.close()
            raise

    def send(self, **value):
        self.process.stdin.write(json.dumps(value) + '\n')
        self.process.stdin.flush()

    def orientation(self):
        value = self.request(self.prefix + '/wda/devicemirror/display')['value']['orientation']
        self.send(type='orientation', value=value)

    def key(self, name, duration=0.08):
        self.orientation()
        self.send(type='key', key=name, phase='down')
        time.sleep(duration)
        self.send(type='key', key=name, phase='up')

    def touch(self, points):
        self.orientation()
        began = time.monotonic()
        for index, sample in enumerate(points):
            time.sleep(max(0, began + sample['time'] - time.monotonic()))
            self.send(type='touch', phase='down' if index == 0 else 'move', x=sample['x'], y=sample['y'])
        last = points[-1]
        self.send(type='touch', phase='up', x=last['x'], y=last['y'])
        time.sleep(.15)

    def back(self, duration=0, expected=200):
        reply = self.request(self.prefix + '/wda/devicemirror/navigation',
                             {'action': 'back', 'resolveOnly': True}, expected)
        if expected == 200 and 'x' in reply['value']:
            point = reply['value']
            self.touch([dict(x=point['x'], y=point['y'], time=0),
                        dict(x=point['x'], y=point['y'], time=max(.05, duration))])
        return reply

    def close(self):
        if self.process.stdin:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=3)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
