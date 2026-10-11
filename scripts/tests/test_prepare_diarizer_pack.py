"""Synthetic assets only. No dependency on downloaded models or network."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('prepare_diarizer_pack', Path(__file__).parents[1] / 'prepare-diarizer-pack.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PrepareDiarizerPackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'snapshot'
        self.target = self.root / 'installed'
        self.manifest = self.root / 'pack.json'
        self.artifacts = []
        for relative, data in [('Segmentation.mlmodelc/weights/weight.bin', bytes(range(256)) * 64),
                               ('Segmentation.mlmodelc/coremldata.bin', b'meta'),
                               ('plda-parameters.json', b'{}'),
                               ('NOTICE.md', b'credit')]:
            path = self.source / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
            self.artifacts.append({'path': 'speaker-diarization/' + relative, 'bytes': len(data),
                                   'sha256': hashlib.sha256(data).hexdigest()})
        self.write_manifest()

    def write_manifest(self):
        self.manifest.write_text(json.dumps({'artifacts': self.artifacts}))

    def prepare(self):
        return module.prepare(self.source, self.target, self.manifest)

    def assert_no_partial_install(self):
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.root.glob('.pomvox-prepare-*')), [])

    def test_copies_nested_layout_exactly_and_publishes_manifest_last(self):
        self.prepare()
        for artifact in self.artifacts:
            installed = self.target / artifact['path']
            self.assertTrue(installed.is_file() and not installed.is_symlink(), artifact['path'])
            self.assertEqual(hashlib.sha256(installed.read_bytes()).hexdigest(), artifact['sha256'])
        self.assertEqual((self.target / 'pack.json').read_bytes(), self.manifest.read_bytes())
        self.assertEqual(sorted(p.name for p in self.target.iterdir()), ['pack.json', 'speaker-diarization'])

    def test_source_symlink_becomes_a_regular_file(self):
        blob = self.root / 'blob'
        original = self.source / 'plda-parameters.json'
        original.rename(blob)
        original.symlink_to(blob)
        self.prepare()
        self.assertFalse((self.target / 'speaker-diarization/plda-parameters.json').is_symlink())

    def test_corruption_missing_and_existing_destination_leave_no_partial_install(self):
        (self.source / 'NOTICE.md').write_bytes(b'credot')
        with self.assertRaises(ValueError):
            self.prepare()
        self.assert_no_partial_install()
        (self.source / 'NOTICE.md').unlink()
        with self.assertRaises((ValueError, OSError)):
            self.prepare()
        self.assert_no_partial_install()
        (self.source / 'NOTICE.md').write_bytes(b'credit')
        self.target.mkdir()
        with self.assertRaises(FileExistsError):
            self.prepare()
        self.assertTrue(self.target.is_dir())

    def test_rejects_flat_absolute_or_traversing_paths(self):
        for bad in ['plda-parameters.json', '/etc/passwd', 'speaker-diarization/../x', 'a/pack.json']:
            with self.subTest(path=bad):
                self.artifacts[0]['path'] = bad
                self.write_manifest()
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assert_no_partial_install()
                self.artifacts[0]['path'] = 'speaker-diarization/Segmentation.mlmodelc/weights/weight.bin'

    def test_pinned_manifest_paths_are_nested_and_unique(self):
        manifest = json.loads(module.MANIFEST.read_text())
        paths = [artifact['path'] for artifact in manifest['artifacts']]
        self.assertEqual(len(paths), len(set(paths)))
        self.assertTrue(all(path.startswith('speaker-diarization/') for path in paths))
        self.assertTrue(all(os.path.normpath(path) == path for path in paths))


if __name__ == '__main__':
    unittest.main()
