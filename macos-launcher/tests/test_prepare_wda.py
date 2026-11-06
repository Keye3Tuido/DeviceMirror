# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prepare_wda', Path(__file__).resolve().parents[1] / 'prepare-wda.py')
prepare_wda = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare_wda)


class PackagedWDATests(unittest.TestCase):
    def test_addition_preserves_vendor_and_invalidates_cached_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, bundle = root / 'vendor', root / 'bundle'
            original = source / 'WebDriverAgentLib/Commands/FBTouchActionCommands.m'
            original.parent.mkdir(parents=True)
            upstream = b'/* Original BSD copyright */\n@implementation FBTouchActionCommands\n@end\n'
            original.write_bytes(upstream)
            (source / 'LICENSE').write_text('Upstream BSD license\n')
            extension = root / 'DMControlCommands.m'
            extension.write_text('// SPDX-License-Identifier: Apache-2.0\n// Own implementation\n')
            with patch.object(prepare_wda.subprocess, 'check_output', return_value='upstream-sha\n'):
                prepare_wda.prepare(source, bundle, extension)
                first = (bundle / 'DEVICE_MIRROR_VERSION').read_text()
                prepare_wda.prepare(source, bundle, extension)
                packaged = bundle / original.relative_to(source)
                self.assertEqual(first, (bundle / 'DEVICE_MIRROR_VERSION').read_text())
                self.assertEqual(original.read_bytes(), upstream)
                self.assertTrue(packaged.read_bytes().startswith(upstream))
                self.assertEqual(packaged.read_text().count('#import "DMControlCommands.m"'), 1)
                self.assertEqual((bundle / 'LICENSE').read_text(), 'Upstream BSD license\n')
                self.assertIn('Apache License', (bundle / 'DEVICE_MIRROR_LICENSE').read_text())
                extension.write_text(extension.read_text() + '// Changed endpoint\n')
                prepare_wda.prepare(source, bundle, extension)
                self.assertNotEqual(first, (bundle / 'DEVICE_MIRROR_VERSION').read_text())
                self.assertEqual((packaged.parent / extension.name).read_bytes(), extension.read_bytes())
