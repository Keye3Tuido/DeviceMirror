# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Keye3Tuido
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prepare_adb', Path(__file__).resolve().parents[1] / 'prepare-adb.py')
prepare_adb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare_adb)


class ADBSourceChecks(unittest.TestCase):
    def test_rejects_changed_cached_source_without_building_it(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'vendor').mkdir()
            (root / 'vendor/source.tar.xz').write_bytes(b'changed')
            catalog = {'source.tar.xz': ('https://example.invalid/source', hashlib.sha256(b'original').hexdigest())}
            with patch.object(prepare_adb, 'ROOT', root), patch.object(prepare_adb, 'ARCHIVES', catalog), patch.object(prepare_adb, 'run') as run:
                with self.assertRaisesRegex(SystemExit, 'checksum mismatch'):
                    prepare_adb.archive('source.tar.xz')
                run.assert_not_called()

    def test_bundled_source_can_be_reused_offline(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            archive = root / 'source.tar.xz'
            archive.write_bytes(b'original')
            catalog = {'source.tar.xz': ('https://example.invalid/source', hashlib.sha256(b'original').hexdigest())}
            with patch.object(prepare_adb, 'ROOT', root), patch.object(prepare_adb, 'ARCHIVES', catalog), patch.object(prepare_adb, 'run') as run:
                self.assertEqual(prepare_adb.archive('source.tar.xz'), archive)
                run.assert_not_called()
