#!/usr/bin/env python3
"""Misst begrenzte CLI-Batches samt Prozessbaum-RSS; überschreibt keine Ausgaben."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import signal
import subprocess
import time


def digest(path):
    value = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            value.update(chunk)
    return value.hexdigest()


def process_tree_rss(pid):
    # Nur PID, Eltern-PID und RSS lesen; Prozessargumente können Secrets enthalten.
    raw = subprocess.check_output(['/bin/ps', '-axo', 'pid=,ppid=,rss='], text=True)
    rows = [tuple(map(int, line.split())) for line in raw.splitlines() if len(line.split()) == 3]
    descendants = {pid}
    while True:
        expanded = descendants | {child for child, parent, _ in rows if parent in descendants}
        if expanded == descendants:
            break
        descendants = expanded
    return sum(rss * 1024 for child, _, rss in rows if child in descendants)


def stop(process):
    if process.poll() is None:
        process.send_signal(signal.SIGINT)
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('workspace', type=Path)
    parser.add_argument('binary', type=Path)
    parser.add_argument('label')
    parser.add_argument('inputs', nargs='+', type=Path)
    parser.add_argument('--jobs', type=int, choices=range(1, 5), required=True)
    parser.add_argument('--runs', type=int, default=3)
    parser.add_argument('--pdf-ocr', choices=['auto', 'always', 'off'])
    parser.add_argument('--compare', type=Path)
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.label) or not 1 <= args.runs <= 20:
        parser.error('label requires letters/digits/_/-; runs must be 1..20')
    if len(args.inputs) < 2 or any(not p.is_file() or p.is_symlink() for p in args.inputs):
        parser.error('provide at least two regular, non-symlink input files')
    inputs = [p.resolve(strict=True) for p in args.inputs]
    binary = args.binary.resolve(strict=True)
    workspace = args.workspace.resolve()
    workspace.mkdir(parents=True, exist_ok=True)
    prefix = f'{args.label}-jobs{args.jobs}'
    manifest = workspace / f'{prefix}.json'
    targets = [(workspace / f'{prefix}-{n}', workspace / f'{prefix}-{n}.stdout.json',
                workspace / f'{prefix}-{n}.stderr') for n in range(args.runs)]
    if manifest.exists() or manifest.is_symlink() or any(p.exists() or p.is_symlink() for triple in targets for p in triple):
        parser.error('measurement label already exists; use a new label')
    sources = [{'name': p.name, 'sha256': digest(p)} for p in inputs]
    comparison = json.loads(args.compare.read_text()) if args.compare else None
    if comparison and comparison['sources'] != sources:
        parser.error('comparison uses different input files or bytes')
    options = {'pdf_ocr': args.pdf_ocr}
    if comparison and comparison.get('options') != options:
        parser.error('comparison uses different conversion options')
    measurements = []
    for trial, (output, stdout, stderr) in enumerate(targets):
        command = [str(binary), *map(str, inputs), '--output', str(output),
                   '--json', '--jobs', str(args.jobs)]
        if args.pdf_ocr:
            command += ['--pdf-ocr', args.pdf_ocr]
        samples = []
        with stdout.open('x') as out, stderr.open('x') as err:
            started = time.monotonic()
            process = subprocess.Popen(command, stdout=out, stderr=err)
            try:
                while process.poll() is None:
                    if time.monotonic() - started > 120:
                        raise RuntimeError('CLI exceeded 120 seconds; partial measurement retained')
                    samples.append(process_tree_rss(process.pid))
                    time.sleep(0.05)
            finally:
                stop(process)
            elapsed = time.monotonic() - started
        if process.returncode:
            raise RuntimeError(f'CLI exited {process.returncode}; inspect {stdout.name} and {stderr.name}')
        result = json.loads(stdout.read_text())
        if not result['ok'] or [Path(r['input']).resolve() for r in result['results']] != inputs:
            raise RuntimeError('batch failed or changed result order')
        if [{'name': p.name, 'sha256': digest(p)} for p in inputs] != sources:
            raise RuntimeError('source bytes changed')
        hashes = {p.relative_to(output).as_posix(): digest(p)
                  for p in sorted(output.rglob('*')) if p.is_file()}
        expected = measurements[0]['output_hashes'] if measurements else (
            comparison['measurements'][0]['output_hashes'] if comparison else hashes)
        if hashes != expected:
            raise RuntimeError('output bytes differ from comparison or first trial')
        measurement = {'trial': trial, 'seconds': elapsed,
                       'sampled_peak_process_tree_bytes': (max(samples) or None) if samples else None,
                       'samples': len(samples), 'output_hashes': hashes}
        measurements.append(measurement)
        print(json.dumps({k: v for k, v in measurement.items() if k != 'output_hashes'}), flush=True)
    with manifest.open('x') as stream:
        json.dump({'jobs': args.jobs, 'options': options, 'sources': sources, 'measurements': measurements}, stream, indent=2)


if __name__ == '__main__':
    main()
