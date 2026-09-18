#!/usr/bin/env python3
"""Prepare an installed snapshot without downloads, source changes or overwrites."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import tempfile


MANIFEST = Path(__file__).resolve().parents[1] / 'packs/simplewords-v3/pack.json'
CHUNK_SIZE = 1024 * 1024


def copy_verified(source, destination, artifact):
    # Hugging Face snapshots use symlinks; inspect the opened target descriptor.
    descriptor = os.open(source, os.O_RDONLY | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_size != artifact['bytes']:
            raise ValueError('invalid source size or type: ' + artifact['path'])
        digest = hashlib.sha256()
        size = 0
        with destination.open('xb') as output:
            while chunk := stream.read(min(CHUNK_SIZE, artifact['bytes'] - size + 1)):
                size += len(chunk)
                if size > artifact['bytes']:
                    raise ValueError('source grew while copying: ' + artifact['path'])
                output.write(chunk)
                digest.update(chunk)
            output.flush()
            os.fsync(output.fileno())
        after = os.fstat(stream.fileno())
        if (size != artifact['bytes'] or digest.hexdigest() != artifact['sha256']
                or (before.st_mtime_ns, before.st_ctime_ns, before.st_size)
                != (after.st_mtime_ns, after.st_ctime_ns, after.st_size)):
            raise ValueError('snapshot does not match pinned artifact: ' + artifact['path'])


def prepare(snapshot, destination, manifest_path=MANIFEST):
    """Verify copied bytes in staging. Publish pack.json last as the commit marker.

    The destination is reserved with an exclusive mkdir. Concurrent installations
    cannot replace each other, even if an existing destination is empty. A failed
    installation removes only the directory this invocation created.
    """
    snapshot, destination = Path(snapshot), Path(destination)
    manifest_data = Path(manifest_path).read_bytes()
    manifest = json.loads(manifest_data)
    paths = [artifact['path'] for artifact in manifest['artifacts']]
    if (not paths or len(set(paths)) != len(paths)
            or any(Path(path).name != path or path in ('.', '..', 'pack.json') for path in paths)):
        raise ValueError('manifest must contain unique flat artifact paths')
    if os.path.lexists(destination):
        raise FileExistsError('destination must not exist; installed packs are immutable')
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.pomvox-prepare-', dir=destination.parent) as stage_name:
        stage = Path(stage_name)
        for artifact in manifest['artifacts']:
            copy_verified(snapshot / artifact['path'], stage / artifact['path'], artifact)
        # mkdir is the exclusive ownership boundary. Never clean up another process's directory.
        destination.mkdir()
        try:
            for path in paths:
                os.replace(stage / path, destination / path)
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
    parser.add_argument('snapshot', type=Path)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    try:
        prepared = prepare(args.snapshot, args.destination)
    except (OSError, ValueError, KeyError) as error:
        parser.exit(1, f'Could not prepare local pack: {error}\n')
    print('Prepared verified local pack:', prepared)


if __name__ == '__main__':
    main()
