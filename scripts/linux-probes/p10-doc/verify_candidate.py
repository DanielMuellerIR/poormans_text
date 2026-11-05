#!/usr/bin/env python3
"""Echte lokale DOC-Konvertierungen; kein Ersatz für die offene Makro-Ereigniskontrolle."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import signal
import subprocess
import tempfile
import time


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli', type=Path, required=True)
    parser.add_argument('--pandoc', type=Path, required=True)
    parser.add_argument('--repo', type=Path, required=True)
    args = parser.parse_args()
    args.cli = args.cli.resolve()
    args.pandoc = args.pandoc.resolve()
    args.repo = args.repo.resolve()
    root = Path(tempfile.mkdtemp(prefix='pmt-doc-candidate-'))
    records = []
    source_root = args.repo / 'Tests/PoorMansTextCoreTests/Fixtures/WordProcessing'
    def run(name, source, flags=(), expected=0):
        target = root / (name + ('.textbundle' if '--textbundle' in flags else ''))
        before = digest(source.read_bytes())
        started = time.monotonic()
        result = subprocess.run([str(args.cli), '--json', '--progress', '--report', '--pandoc', str(args.pandoc), '--output', str(target)] + list(flags) + ['--', str(source)], capture_output=True, timeout=35)
        response = json.loads(result.stdout)
        checks = {'expectedExit': result.returncode == expected, 'sourceUnchanged': digest(source.read_bytes()) == before}
        record = {'case': name, 'exit': result.returncode, 'seconds': round(time.monotonic()-started, 4), 'checks': checks, 'response': response, 'stderr': result.stderr.decode()}
        if expected:
            checks['noOutput'] = not target.exists()
            checks['noStaging'] = not list(root.glob('.poormans-text-*'))
        if response['ok']:
            text = Path(response['markdownFile']).read_text()
            normalized = re.sub(r'\s+', ' ', text)
            for marker in ['Fixture heading ä', 'First list item', 'Second list item', 'Äpfel', '12', 'Birnen', '7', 'Grüße aus Köln'] + (['Footnote content remains readable.'] if source.name == 'libreoffice.doc' else []):
                checks['text:'+marker] = marker in normalized
            checks['twoReadableListItems'] = len(re.findall(r'^(?:- |• )', text, re.M)) == 2
            record['semanticMarkdownListItems'] = len(re.findall(r'^- ', text, re.M))
            record['literalBulletParagraphs'] = len(re.findall(r'^• ', text, re.M))
            checks['legacyWarning'] = any(d['code'] == 'legacyWord.potentialLoss' for d in response['diagnostics'])
            report = json.loads(Path(response['reportFile']).read_text())
            checks['sourceHash'] = report['source']['sha256'] == before and report['source']['byteCount'] == source.stat().st_size
            for item in report['outputs']:
                data = (target / item['path']).read_bytes()
                checks['manifest:'+item['path']] = digest(data) == item['sha256'] and len(data) == item['byteCount']
            if source.name == 'libreoffice.doc':
                checks['oneImage'] = len(response['assets']) == 1
                if response['assets']: checks['originalPNGBytes'] = Path(response['assets'][0]).read_bytes() == (source_root / 'fixture.png').read_bytes()
            record['markdown'] = text
        records.append(record)
    run('libreoffice', source_root / 'libreoffice.doc')
    run('textutil', source_root / 'textutil.doc')
    run('textbundle', source_root / 'libreoffice.doc', ['--textbundle'])
    run('timeout', source_root / 'libreoffice.doc', ['--timeout', '0.01'], 124)
    invalid = root / 'invalid.doc'
    invalid.write_bytes(b'not a Word OLE document')
    run('invalid', invalid, expected=65)
    target = root / 'cancelled'
    source = source_root / 'libreoffice.doc'
    before = digest(source.read_bytes())
    process = subprocess.Popen([str(args.cli), '--json', '--progress', '--pandoc', str(args.pandoc), '--output', str(target), '--', str(source)], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(.15)
    process.send_signal(signal.SIGTERM)
    stdout, stderr = process.communicate(timeout=15)
    records.append({'case': 'cancel', 'exit': process.returncode, 'response': json.loads(stdout), 'stderr': stderr.decode(), 'checks': {'cancelled130': process.returncode==130, 'sourceUnchanged': digest(source.read_bytes()) == before, 'noOutput': not target.exists(), 'noStaging': not list(root.glob('.poormans-text-*'))}})
    evidence = {'cases': records, 'macroEventPositiveControl': False, 'macroSafetyAccepted': False}
    (root / 'evidence.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2))
    failures = [{'case': r['case'], 'check': c} for r in records for c, passed in r['checks'].items() if not passed]
    summary = {'runRoot': str(root), 'cases': len(records), 'checks': sum(len(r['checks']) for r in records), 'failures': failures, 'macroSafetyAccepted': False}
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return bool(failures)


if __name__ == '__main__':
    raise SystemExit(main())
