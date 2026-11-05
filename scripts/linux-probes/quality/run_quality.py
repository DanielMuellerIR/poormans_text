#!/usr/bin/env python3
"""Begrenzter Offline-Qualitätslauf mit unabhängigen Sollwerten und expliziten Lücken."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--repo', required=True, type=Path)
parser.add_argument('--cli', required=True, type=Path)
parser.add_argument('--root', required=True, type=Path)
parser.add_argument('--expected-cli-sha256', required=True)
parser.add_argument('--structured-runtime', choices=['unavailable', 'available'], default='unavailable')
args = parser.parse_args()
actual_hash = hashlib.sha256(args.cli.read_bytes()).hexdigest()
if actual_hash != args.expected_cli_sha256:
    parser.error('CLI identity mismatch; select the reviewed artifact explicitly')
args.root.mkdir(exist_ok=False)
scripts = args.repo / 'scripts/linux-probes'
here = Path(__file__).resolve().parent
rows = []


def run(name, command, *, optional=False):
    try:
        result = subprocess.run(list(map(str, command)), capture_output=True, text=True, timeout=180)
        status = result.returncode
        stdout, stderr = result.stdout, result.stderr
    except subprocess.TimeoutExpired as error:
        status = 124
        stdout = error.stdout or b''
        stderr = error.stderr or b''
        stdout = stdout.decode('utf-8', errors='replace') if isinstance(stdout, bytes) else stdout
        stderr = stderr.decode('utf-8', errors='replace') if isinstance(stderr, bytes) else stderr
        stderr += '\nQuality probe exceeded its 180-second limit.\n'
    (args.root / (name + '.stdout')).write_text(stdout)
    (args.root / (name + '.stderr')).write_text(stderr)
    rows.append(dict(capability=name, status='PASS' if status == 0 else ('SKIP' if optional and status == 2 else 'FAIL'), exit=status))


run('families', [sys.executable, here / 'quality.py', '--repo', args.repo, '--cli', args.cli,
                 '--results', args.root / 'families'])
run('raster-ocr', [sys.executable, scripts / 'p09/verify_images.py', '--cli', args.cli,
                   '--font', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf',
                   '--evidence', args.root / 'images.json', '--structured-runtime', args.structured_runtime])
run('pdf-synthetic', [sys.executable, scripts / 'p09/verify_pdf.py', '--cli', args.cli,
                      '--root', args.root / 'pdf', '--structured-runtime', args.structured_runtime])
corpus = args.repo / 'docs/linux-port/P11-NATURAL-EVIDENCE/inputs'
if all((corpus / name).is_file() for name in ['01030000000132.pdf', '01030000000134.pdf', '01030000000135.pdf']):
    run('natural-integrity', [sys.executable, scripts / 'p11/natural_benchmark.py', '--cli', args.cli,
                              '--corpus', corpus, '--root', args.root / 'natural'])
    evidence = args.root / 'natural/evidence.json'
    if evidence.exists():
        for case in json.loads(evidence.read_text())['cases']:
            analysis = case.get('analysis', {})
            words = analysis.get('wordInventory', {})
            missing = sum(words.get('missing', {}).values())
            extra = sum(words.get('extra', {}).values())
            cells = analysis.get('cells', [])
            passed = (bool(case.get('integrityPassed')) and not missing
                      and analysis.get('foundAnchorsInGTOrder')
                      and all(cell['exactTokenSequenceFound'] for cell in cells))
            rows.append(dict(capability=case['source'] + '-' + case['mode'] + '-text',
                             status='PASS' if passed else 'FAIL', matched=words.get('matched'),
                             expected=words.get('expected'), missing=missing, extra=extra,
                             diagnostics=analysis.get('diagnosticCodes'),
                             allFoundAnchorsInOrder=analysis.get('foundAnchorsInGTOrder'),
                             cellsFound=sum(cell['exactTokenSequenceFound'] for cell in cells),
                             expectedCells=len(cells)))
            if cells:
                structured = analysis.get('tableStructurePresent') and analysis.get('colspanPresent')
                rows.append(dict(capability=case['source'] + '-' + case['mode'] + '-table-structure',
                                 status='PASS' if structured else 'FAIL'))
else:
    rows.append(dict(capability='natural corpus', status='SKIP', reason='Fixed licensed local corpus missing; no download'))
run('structured OCR quality', [sys.executable, here / 'structured_quality.py',
                                '--cli', args.cli, '--results', args.root / 'structured'],
    optional=args.structured_runtime == 'unavailable')
overall = 'FAIL' if any(row['status'] == 'FAIL' for row in rows) else (
    'INCOMPLETE' if any(row['status'] == 'SKIP' for row in rows) else 'PASS')
summary = dict(cliSHA256=actual_hash, python=sys.version.split()[0], cases=rows, overall=overall,
               scope='Bounded fixtures; no visual or complete format-matrix approval')
(args.root / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(summary, ensure_ascii=False, indent=2))
# Nur eigene, regenerierbare Bildausgaben entfernen; Fehler- und Textbelege behalten.
for directory in (args.root / 'natural', args.root / 'pdf/outputs'):
    if directory.exists():
        for images in directory.rglob('images'):
            shutil.rmtree(images)
raise SystemExit({'PASS': 0, 'FAIL': 1, 'INCOMPLETE': 2}[overall])
