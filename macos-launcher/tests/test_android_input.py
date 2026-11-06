# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
import base64
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
METHOD = 'com.keye3tuido.devicemirror.input/.TextInputService'
PREVIOUS = 'com.example.keyboard/.Keyboard'
FAKE_ADB = '''#!/usr/bin/python3
import base64,json,os,sys
from pathlib import Path
p=Path(os.environ['DM_INPUT_TEST_STATE'])
s=json.loads(p.read_text())
assert sys.argv[1:3] == ['-s','device with spaces;$(exit)']
a=sys.argv[3:]
s['calls'].append(a)
status=0
output=''
if a[:4] == ['shell','settings','get','secure']: output=s['current']
elif a[:4] == ['shell','ime','list','-s']: output=s['current']
elif a[:3] == ['shell','pm','path']:
    if s['installed']: output='package:/data/app/input.apk'
    else: status=1
elif a[:3] == ['install','-r','--no-streaming']: s['installed']=True;output='Success'
elif a[:3] == ['shell','ime','enable']: s['enabled']=True
elif a[:3] == ['shell','ime','disable']: s['enabled']=False
elif a[:3] == ['shell','ime','set']: s['current']=a[3]
elif a[:3] == ['shell','am','broadcast']:
    action=a[a.index('-a')+1].split('.')[-1]
    if action == 'PING': output='Broadcast completed: result='+('1' if s['ready'] else '2')
    else:
        assert action=='COMMIT'
        s['commits'].append(base64.b64decode(a[-1]).decode())
        output='Broadcast completed: result='+('1' if s['accept'] else '3')
        if s.get('uncertain'): status=7
else: raise AssertionError(a)
p.write_text(json.dumps(s))
print(output)
sys.exit(status)
'''

class AndroidInputTests(unittest.TestCase):
    def run_send(self, *, ready=True, accept=True, uncertain=False):
        payload = '中文 English 😀\n"\'$(exit);\\'
        with tempfile.TemporaryDirectory(prefix='dm-input-') as directory:
            directory = Path(directory)
            state = directory / 'state.json'
            state.write_text(json.dumps(dict(current=PREVIOUS, installed=False, enabled=False,
                                             ready=ready, accept=accept, uncertain=uncertain, calls=[], commits=[])))
            adb = directory / 'fake adb'
            adb.write_text(FAKE_ADB)
            adb.chmod(0o700)
            env = dict(os.environ, DM_INPUT_TEST_STATE=str(state))
            result = subprocess.run([str(ROOT / '.build/android-input-tests-service'), str(adb),
                                     'device with spaces;$(exit)', str(directory / 'input.apk')],
                                    input=payload, text=True, capture_output=True, env=env, timeout=25)
            return payload, result, json.loads(state.read_text())

    def assert_restored(self, state):
        self.assertEqual(state['current'], PREVIOUS)
        self.assertFalse(state['enabled'])
        self.assertFalse(any('clipboard' in ' '.join(call).lower() for call in state['calls']))

    def test_unicode_once_and_restore(self):
        payload, result, state = self.run_send()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state['commits'], [payload])
        self.assert_restored(state)

    def test_missing_focus_does_not_commit(self):
        _, result, state = self.run_send(ready=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('焦点', result.stderr)
        self.assertEqual(state['commits'], [])
        self.assert_restored(state)

    def test_editor_rejection_is_not_retried(self):
        payload, result, state = self.run_send(accept=False)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state['commits'], [payload])
        self.assert_restored(state)

    def test_uncertain_commit_is_not_retried(self):
        payload, result, state = self.run_send(uncertain=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('可能已送达', result.stderr)
        self.assertEqual(state['commits'], [payload])
        self.assert_restored(state)

    def test_component_has_no_clipboard_or_network(self):
        source = (ROOT / 'AndroidInput/src/com/keye3tuido/devicemirror/input/TextInputService.java').read_text()
        manifest = (ROOT / 'AndroidInput/AndroidManifest.xml').read_text()
        self.assertNotIn('ClipboardManager', source)
        self.assertNotIn('android.permission.INTERNET', manifest)
        self.assertNotIn('<activity', manifest)
        self.assertIn('android.permission.DUMP', source)
        self.assertIn('connection.commitText(text, 1)', source)
