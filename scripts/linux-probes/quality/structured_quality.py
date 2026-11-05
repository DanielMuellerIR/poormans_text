#!/usr/bin/env python3
"""Vergleicht echte strukturierte Produkt-OCR mit einer unabhängigen Zeichenreferenz."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cli', required=True, type=Path)
parser.add_argument('--results', required=True, type=Path)
args = parser.parse_args()
args.results.mkdir(exist_ok=False)
fixtures = Path(__file__).with_name('fixtures')
source = fixtures / 'structured.png'
reference = json.loads((fixtures / 'structured-reference.json').read_text())


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


before = digest(source)
assert before == reference['sourceSHA256'], 'Unreviewed structured quality fixture'
report = dict(cliSHA256=digest(args.cli), sourceSHA256=before, status='FAIL')
with tempfile.TemporaryDirectory(prefix='pmt-structured-quality-') as temporary:
    destination = Path(temporary) / 'output'
    result = subprocess.run([str(args.cli), '--json', '--report', '--source-map',
                             '--ocr-method', 'structured', '--ocr-language', 'en',
                             '--output', str(destination), '--', str(source)],
                            capture_output=True, text=True, timeout=150)
    report['exit'] = result.returncode
    try:
        response = json.loads(result.stdout)
        if result.returncode == 69:
            assert not destination.exists(), 'Unavailable backend published output'
            report.update(status='SKIP', reason=response.get('error', 'Local structured OCR unavailable'))
        else:
            assert result.returncode == 0, (result.stdout, result.stderr)
            markdown = Path(response['markdownFile']).read_text()
            (args.results / 'output.md').write_text(markdown)
            identity = response.get('sourceIdentity') or {}
            assert identity.get('sha256') == before and identity.get('byteCount') == source.stat().st_size
            assert digest(source) == before, 'Source changed'
            for entry in response['outputFiles']:
                relative = Path(entry['path'])
                assert not relative.is_absolute() and '..' not in relative.parts
                file = destination / relative
                assert not file.is_symlink() and file.is_file()
                assert digest(file) == entry['sha256'], 'Output manifest mismatch'
            assert any(digest(p) == before for p in (destination / 'images').iterdir()), 'Original asset missing'
            codes = [item['code'] for item in response.get('diagnostics', [])]
            assert 'ocr.structuredApplied' in codes, 'No structured product result'
            lines = [line for line in markdown.splitlines() if line.startswith('|')]
            separators = [i for i, line in enumerate(lines) if '-' in line and re.fullmatch(r'[| :\-]+', line)]
            assert separators == [1], 'Expected one rendered table'
            rows = [[cell.strip() for cell in line.strip().strip('|').split('|')]
                    for i, line in enumerate(lines) if i != 1]
            assert rows and rows[0] == ['', '', ''], 'Unexpected table header'
            rows = rows[1:]
            shape = len(rows) == 3 and all(len(row) == 3 for row in rows)
            details = []
            for row, expected in enumerate(reference['cells']):
                for column, text in enumerate(expected):
                    if not text:
                        continue
                    actual = rows[row][column] if row < len(rows) and column < len(rows[row]) else None
                    details.append(dict(row=row, column=column, expected=text, actual=actual, exact=actual == text))
            body_lines = []
            for line in markdown.split('|', 1)[0].splitlines():
                line = line.strip()
                if not line or line.startswith(('#', '![')):
                    continue
                body_lines.append(re.sub(r'^\d+\\?\.\s+', '', line))
            body = {text: body_lines.count(text) == 1 for text in reference['body']}
            body_order = body_lines == reference['body']
            covered = shape and rows[0][1] == '' and 'ocr.tableSpansFlattened' in codes
            passed = shape and covered and body_order and all(body.values()) and all(cell['exact'] for cell in details)
            report.update(status='PASS' if passed else 'FAIL', integrityPassed=True,
                          exactCellTexts=sum(cell['exact'] for cell in details), expectedCellTexts=8,
                          tableShapePassed=shape, coveredMergedSlotEmpty=covered,
                          bodyInventory=body, exactBodyOrderAndInventory=body_order, cells=details, diagnostics=codes,
                          scope='Final Markdown grid; original model span geometry is not inferred from flattened Markdown')
            (args.results / 'output.md').write_text(markdown)
    except Exception as error:
        report.update(status='FAIL', error=str(error), stderr=result.stderr)
    assert digest(source) == before
(args.results / 'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(report, ensure_ascii=False, indent=2))
raise SystemExit({'PASS': 0, 'FAIL': 1, 'SKIP': 2}[report['status']])
