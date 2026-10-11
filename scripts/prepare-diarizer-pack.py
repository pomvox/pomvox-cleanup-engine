#!/usr/bin/env python3
"""Prepare an installed diarizer pack from an already obtained model snapshot. No downloads, no overwrites."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import tempfile

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'packs/pyannote-community1-coreml/pack.json'

_spec = importlib.util.spec_from_file_location('prepare_local_pack', Path(__file__).resolve().parent / 'prepare-local-pack.py')
_local = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_local)
copy_verified = _local.copy_verified


def _safe_relative(path):
    parts = Path(path).parts
    if not parts or Path(path).is_absolute() or any(part in ('.', '..', '') for part in parts) or parts[-1] == 'pack.json':
        raise ValueError('manifest artifact paths must be relative and well formed: ' + path)
    return Path(*parts)


def prepare(snapshot, destination, manifest_path=MANIFEST):
    """Copy and verify every pinned artifact into staging, then publish atomically.

    `snapshot` is the model repository as downloaded (bundles at its root). Manifest
    paths carry the models folder as their first component; the source path is the
    remainder. The destination is reserved with an exclusive mkdir and `pack.json`
    is written last as the commit marker. A failure removes only what this call made.
    """
    snapshot, destination = Path(snapshot), Path(destination)
    manifest_data = Path(manifest_path).read_bytes()
    manifest = json.loads(manifest_data)
    paths = [_safe_relative(artifact['path']) for artifact in manifest['artifacts']]
    if not paths or len(set(paths)) != len(paths) or any(len(path.parts) < 2 for path in paths):
        raise ValueError('manifest must contain unique nested artifact paths')
    if os.path.lexists(destination):
        raise FileExistsError('destination must not exist; installed packs are immutable')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.pomvox-prepare-', dir=destination.parent) as stage_name:
        stage = Path(stage_name)
        for artifact, path in zip(manifest['artifacts'], paths):
            source = snapshot.joinpath(*path.parts[1:])
            target = stage / path
            target.parent.mkdir(parents=True, exist_ok=True)
            copy_verified(source, target, artifact)
        destination.mkdir()
        try:
            for entry in sorted(stage.iterdir()):
                os.replace(entry, destination / entry.name)
            with (destination / 'pack.json').open('xb') as output:
                output.write(manifest_data)
                output.flush()
                os.fsync(output.fileno())
        except BaseException:
            shutil.rmtree(destination)
            raise
    return destination


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('snapshot', type=Path, help='downloaded model repository root (bundles at top level)')
    parser.add_argument('destination', type=Path, help='new directory to create')
    parser.add_argument('--manifest', type=Path, default=MANIFEST)
    args = parser.parse_args()
    try:
        prepared = prepare(args.snapshot, args.destination, args.manifest)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'Could not prepare diarizer pack: {error}\n')
    print('Prepared verified diarizer pack:', prepared)


if __name__ == '__main__':
    main()
