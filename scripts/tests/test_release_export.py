import importlib.util
import json
from pathlib import Path
import tempfile
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('release_export', ROOT / 'scripts/export-mlx-release.py')
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ReleaseExportTests(unittest.TestCase):
    def test_export_is_remote_and_matches_runtime_source(self):
        with tempfile.TemporaryDirectory() as parent:
            destination = MODULE.export(Path(parent) / 'runtime')
            manifest = (destination / 'Package.swift').read_text()
            version = (ROOT / 'VERSION').read_text().strip()
            parsed = subprocess.run(['swift', 'package', '--package-path', str(destination), 'dump-package'],
                check=True, capture_output=True, text=True, timeout=60)
            package = json.loads(parsed.stdout)
            self.assertEqual(package['name'], 'PomvoxCleanupMLX')
            runtime = next(t for t in package['targets'] if t['name'] == 'PomvoxCleanupMLX')
            self.assertTrue(any(d.get('product', [])[:2] == ['Tokenizers', 'swift-tokenizers']
                                for d in runtime['dependencies']))
            self.assertNotIn('path: "../.."', manifest)
            self.assertIn('exact: "' + version + '"', manifest)
            self.assertIn('https://github.com/pomvox/pomvox-cleanup-engine.git', manifest)
            self.assertNotIn('@SDK_VERSION@', (destination / 'README.md').read_text())
            for source in (ROOT / 'Runtime/MLX/Sources').rglob('*.swift'):
                self.assertEqual(source.read_bytes(), (destination / source.relative_to(ROOT / 'Runtime/MLX')).read_bytes())
            self.assertEqual(json.loads((destination / 'SOURCE.json').read_text())['tag'], 'v' + version)
            self.assertFalse(list(destination.rglob('*.safetensors')))
            self.assertTrue((destination / '.github/workflows/ci.yml').is_file())

    def test_never_overwrites_an_existing_destination(self):
        with tempfile.TemporaryDirectory() as parent:
            destination = Path(parent) / 'runtime'
            destination.mkdir()
            marker = destination / 'user-file'
            marker.write_text('keep me')
            with self.assertRaises(FileExistsError):
                MODULE.export(destination)
            self.assertEqual(marker.read_text(), 'keep me')

    def test_repeated_exports_have_identical_contents(self):
        with tempfile.TemporaryDirectory() as parent:
            first = MODULE.export(Path(parent) / 'first')
            second = MODULE.export(Path(parent) / 'second')
            self.assertEqual((first / 'SOURCE.json').read_bytes(), (second / 'SOURCE.json').read_bytes())
