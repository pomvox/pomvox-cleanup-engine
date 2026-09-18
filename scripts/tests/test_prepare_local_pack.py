"""Synthetic assets only. No dependency on an installed model or network."""
import concurrent.futures
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('prepare_pack', Path(__file__).parents[1] / 'prepare-local-pack.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PreparePackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'snapshot'
        self.source.mkdir()
        self.target = self.root / 'installed'
        self.manifest = self.root / 'pack.json'
        self.artifacts = []
        for name, data in [('config.json', b'{}'), ('weights', bytes(range(256)) * 8192)]:
            (self.source / name).write_bytes(data)
            self.artifacts.append({'path': name, 'bytes': len(data), 'sha256': hashlib.sha256(data).hexdigest()})
        self.write_manifest()

    def write_manifest(self):
        self.manifest.write_text(json.dumps({'artifacts': self.artifacts}))

    def prepare(self):
        return module.prepare(self.source, self.target, self.manifest)

    def assert_no_partial_install(self):
        self.assertFalse(self.target.exists())
        self.assertEqual(list(self.root.glob('.pomvox-prepare-*')), [])

    def test_copies_exact_bytes_and_does_not_modify_source(self):
        before = {p.name: (p.read_bytes(), p.stat().st_mtime_ns) for p in self.source.iterdir()}
        self.prepare()
        self.assertEqual((self.target / 'pack.json').read_bytes(), self.manifest.read_bytes())
        for name, (data, mtime) in before.items():
            self.assertEqual((self.target / name).read_bytes(), data)
            self.assertEqual((self.source / name).read_bytes(), data)
            self.assertEqual((self.source / name).stat().st_mtime_ns, mtime)

    def test_hugging_face_style_source_symlink(self):
        blob = self.root / 'blob'
        (self.source / 'weights').rename(blob)
        (self.source / 'weights').symlink_to(blob)
        self.prepare()
        self.assertFalse((self.target / 'weights').is_symlink())
        self.assertEqual((self.target / 'weights').read_bytes(), blob.read_bytes())

    def test_same_size_corruption_leaves_no_destination(self):
        (self.source / 'config.json').write_bytes(b'[]')
        with self.assertRaises(ValueError):
            self.prepare()
        self.assert_no_partial_install()

    def test_missing_truncated_and_special_sources_fail_without_hanging(self):
        source = self.source / 'weights'
        for kind in ['missing', 'short', 'directory', 'fifo']:
            with self.subTest(kind=kind):
                if source.is_dir(): source.rmdir()
                elif source.exists(): source.unlink()
                if kind == 'short': source.write_bytes(b'x')
                elif kind == 'directory': source.mkdir()
                elif kind == 'fifo': os.mkfifo(source)
                with self.assertRaises((ValueError, OSError)):
                    self.prepare()
                self.assert_no_partial_install()

    def test_existing_directory_and_dangling_symlink_are_preserved(self):
        self.target.mkdir()
        sentinel = self.target / 'unrelated'
        sentinel.write_text('keep')
        with self.assertRaises(FileExistsError): self.prepare()
        self.assertEqual(sentinel.read_text(), 'keep')
        sentinel.unlink()
        self.target.rmdir()
        self.target.symlink_to(self.root / 'missing')
        with self.assertRaises(FileExistsError): self.prepare()
        self.assertTrue(self.target.is_symlink())

    def test_concurrent_installers_have_one_winner(self):
        def attempt(_):
            try:
                self.prepare()
                return True
            except FileExistsError:
                return False
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            outcomes = list(pool.map(attempt, range(4)))
        self.assertEqual(sum(outcomes), 1)
        self.assertEqual((self.target / 'weights').read_bytes(), (self.source / 'weights').read_bytes())
        self.assertEqual(list(self.root.glob('.pomvox-prepare-*')), [])

    def test_publication_failure_cleans_only_owned_destination(self):
        with patch.object(module.os, 'replace', side_effect=OSError('injected disk failure')):
            with self.assertRaises(OSError): self.prepare()
        self.assert_no_partial_install()

    def test_manifest_is_published_after_all_artifacts(self):
        original = module.os.replace
        def inspect(src, dst):
            self.assertFalse((self.target / 'pack.json').exists())
            original(src, dst)
        with patch.object(module.os, 'replace', side_effect=inspect):
            self.prepare()
        self.assertTrue((self.target / 'pack.json').is_file())

    def test_traversal_duplicate_and_reserved_names_rejected(self):
        for path in ['../escape', '/absolute', 'nested/file', '.', '..', 'pack.json', 'config.json']:
            with self.subTest(path=path):
                self.artifacts[1]['path'] = path
                self.write_manifest()
                with self.assertRaises(ValueError): self.prepare()
                self.assert_no_partial_install()


if __name__ == '__main__':
    unittest.main()
