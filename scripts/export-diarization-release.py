#!/usr/bin/env python3
"""Export the standalone, remotely consumable diarization package. Never publishes or downloads."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil

ROOT = Path(__file__).resolve().parents[1]


def export(destination, root=ROOT):
    destination, root = Path(destination), Path(root)
    version = (root / 'VERSION').read_text().strip()
    if not re.fullmatch(
            r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?', version):
        raise ValueError('VERSION must be a semantic version without build metadata')
    source = root / 'Runtime/Diarization'
    manifest = (source / 'Package.swift').read_text()
    local = '.package(name: "PomvoxCleanup", path: "../..")'
    if manifest.count(local) != 1:
        raise ValueError('expected exactly one development-only core dependency')
    manifest = manifest.replace(local,
        '.package(url: "https://github.com/pomvox/pomvox-cleanup-engine.git", exact: "' + version + '")')
    manifest = manifest.replace('package: "PomvoxCleanup"', 'package: "pomvox-cleanup-engine"')
    destination.mkdir(parents=True, exist_ok=False)
    try:
        (destination / 'Package.swift').write_text(manifest)
        for directory in ['Sources', 'Tests', 'Examples']:
            for path in sorted((source / directory).rglob('*.swift')):
                target = destination / path.relative_to(source)
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, target)
        for name in ['LICENSE', 'VERSION', 'THIRD_PARTY_NOTICES.md']:
            shutil.copyfile(root / name, destination / name)
        packs = destination / 'packs/pyannote-community1-coreml'
        packs.mkdir(parents=True)
        shutil.copyfile(root / 'packs/pyannote-community1-coreml/pack.json', packs / 'pack.json')
        (destination / 'README.md').write_text(
            (root / 'docs/releases/DIARIZATION-README.md').read_text().replace('@SDK_VERSION@', version))
        (destination / '.gitignore').write_text('.build/\n.swiftpm/\n*.mlmodelc/\n*.wav\n.DS_Store\n')
        (destination / '.github/workflows').mkdir(parents=True)
        shutil.copyfile(root / '.github/standalone-diarization-ci.yml', destination / '.github/workflows/ci.yml')
        hashes = {str(p.relative_to(destination)): hashlib.sha256(p.read_bytes()).hexdigest()
                  for p in sorted(destination.rglob('*')) if p.is_file()}
        (destination / 'SOURCE.json').write_text(json.dumps({
            'repository': 'https://github.com/pomvox/pomvox-cleanup-engine',
            'tag': 'v' + version, 'filesSHA256': hashes}, indent=2) + '\n')
    except BaseException:
        shutil.rmtree(destination)
        raise
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    args = parser.parse_args()
    print(export(args.destination))
