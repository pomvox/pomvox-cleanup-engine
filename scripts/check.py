#!/usr/bin/env python3
"""Run the offline SDK checks. MLX parity requires the separate installed-pack procedure."""
import argparse
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def run(name, command, directory, timeout=600):
    log = directory / (name + '.log')
    started = time.monotonic()
    print(f'{name}: running (log: {log})', flush=True)
    with log.open('w') as output:
        process = subprocess.Popen(command, cwd=ROOT, stdout=output, stderr=subprocess.STDOUT,
                                   start_new_session=True)
        try:
            status = process.wait(timeout=timeout)
        except BaseException:
            # Include loopback fixture children when a suite hangs or is interrupted.
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise
    if status:
        print(log.read_text()[-12000:], file=sys.stderr)
        raise RuntimeError(f'{name} failed with exit status {status}; see {log}')
    return {'name': name, 'exitCode': status, 'seconds': round(time.monotonic() - started, 3)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build-dir', type=Path, help='disposable output directory; default: a new /tmp directory')
    parser.add_argument('--sanitizers', action='store_true', help='also run separate thread and address sanitizer builds')
    parser.add_argument('--repeat', type=int, default=1, help='repeat lifecycle tests 1–100 times after the full suites')
    args = parser.parse_args()
    if not 1 <= args.repeat <= 100:
        parser.error('--repeat must be 1–100')
    directory = (args.build_dir or Path(tempfile.mkdtemp(prefix='pomvox-check-', dir='/tmp'))).resolve()
    directory.mkdir(parents=True, exist_ok=True)
    checks = []
    try:
        checks.append(run('installer', [sys.executable, '-m', 'unittest', 'discover', '-s', 'scripts/tests', '-v'], directory))
        debug = ['swift', 'test', '--scratch-path', str(directory / 'debug'), '--enable-code-coverage', '-Xswiftc', '-warnings-as-errors']
        checks.append(run('debug', debug, directory))
        # Later filtered runs overwrite SwiftPM's coverage output; preserve the full suite.
        for report in (directory / 'debug').glob('*/debug/codecov/*.json'):
            shutil.copyfile(report, directory / 'coverage.json')
        checks.append(run('release', ['swift', 'test', '-c', 'release', '--scratch-path', str(directory / 'release'),
                                     '-Xswiftc', '-warnings-as-errors'], directory))
        for iteration in range(args.repeat):
            checks.append(run(f'lifecycle-{iteration + 1}', debug + ['--skip-build', '--filter', 'LifecycleTests'], directory))
        if args.sanitizers:
            for sanitizer in ['thread', 'address']:
                checks.append(run(sanitizer, ['swift', 'test', '--scratch-path', str(directory / sanitizer),
                                             '--sanitize=' + sanitizer], directory))
    finally:
        (directory / 'checks.json').write_text(json.dumps({'completedChecks': checks,
            'modelTests': 'not run; follow docs/testing.md with a pinned installed pack'}, indent=2) + '\n')
    print(f'All requested checks passed. Evidence: {directory}')
    print('Live-model parity, app integration and release gates are separate; see docs/testing.md.')


if __name__ == '__main__':
    main()
