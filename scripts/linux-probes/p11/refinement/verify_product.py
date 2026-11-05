#!/usr/bin/env python3
"""Echte Produkt-OCR gegen vorher festgelegte Referenzen und den alten Modellstand."""
import argparse
from collections import Counter
import difflib
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
here = Path(__file__).resolve().parent
references = json.loads((here / 'fixtures/reference.json').read_text())
baseline = json.loads((here / 'baseline.json').read_text())
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
tokens = lambda text: re.findall(r'\w+', text.casefold())
summary = {'cliSHA256': sha(args.cli), 'regressionStatus': 'FAIL', 'qualityStatus': 'FAIL', 'cases': []}
refinements = 0
for reference in references:
    name = reference['case']
    source = here / 'fixtures' / (name + '.png')
    assert sha(source) == reference['sourceSHA256'] == baseline[name]['sourceSHA256']
    with tempfile.TemporaryDirectory(prefix='pmt-refinement-product-') as temporary:
        output = Path(temporary) / 'output'
        result = subprocess.run([str(args.cli), '--json', '--report', '--ocr-method', 'structured',
                                 '--ocr-language', 'en,de', '--output', str(output), '--', str(source)],
                                capture_output=True, text=True, timeout=150)
        assert result.returncode == 0, (name, result.stdout, result.stderr)
        response = json.loads(result.stdout)
        markdown = Path(response['markdownFile']).read_text()
        (args.results / (name + '.md')).write_text(markdown)
        for item in response['outputFiles']:
            relative = Path(item['path'])
            assert not relative.is_absolute() and '..' not in relative.parts
            assert sha(output / relative) == item['sha256']
        assert sha(source) == reference['sourceSHA256']
        assert response['sourceIdentity']['sha256'] == reference['sourceSHA256']
        codes = [item['code'] for item in response['diagnostics']]
        assert 'ocr.structuredApplied' in codes
        refinements += 'ocr.wordRefinementApplied' in codes
        text = markdown.split('## OCR text\n\n', 1)[1]
        text = re.sub(r'\\([!"#$%&\'()*+,\-./:;<=>?@\[\]\\^_`{|}~])', r'\1', text)
        rows = [[cell.strip() for cell in line.strip().strip('|').split('|')]
                for line in text.splitlines() if line.startswith('|') and not re.fullmatch(r'[| :\-]+', line)]
        if rows and not any(rows[0]): rows = rows[1:]
        body = [line.strip() for line in text.split('|', 1)[0].splitlines() if line.strip()]
        expected = Counter(tokens(' '.join(reference['body'] + [v for row in reference['cells'] for v in row])))
        actual = Counter(tokens(text))
        losses = []
        for index, expected_line in enumerate(reference['body']):
            wanted = expected_line.split()
            def correct_positions(lines):
                found = lines[index].split() if index < len(lines) else []
                return {k for block in difflib.SequenceMatcher(a=wanted, b=found, autojunk=False).get_matching_blocks()
                        for k in range(block.a, block.a + block.size)}
            for position in sorted(correct_positions(baseline[name]['bodyLines']) - correct_positions(body)):
                losses.append({'line': index, 'token': position, 'expected': wanted[position]})
        for row_index, row in enumerate(reference['cells']):
            for column, wanted in enumerate(row):
                old = baseline[name]['cellTexts']
                old_value = old[row_index][column] if row_index < len(old) and column < len(old[row_index]) else None
                new_value = rows[row_index][column] if row_index < len(rows) and column < len(rows[row_index]) else None
                if old_value == wanted and new_value != wanted:
                    losses.append({'row': row_index, 'column': column, 'expected': wanted, 'actual': new_value})
        matched = sum((expected & actual).values())
        summary['cases'].append({'case': name, 'sourceSHA256': sha(source), 'sourceUnchanged': True,
                                 'outputManifestVerified': True, 'baselineMatched': baseline[name]['matched'],
                                 'matched': matched, 'expected': sum(expected.values()),
                                 'missing': dict(expected - actual), 'extra': dict(actual - expected),
                                 'newCorrectToWrongPositions': losses, 'exactGrid': rows == reference['cells'],
                                 'diagnostics': codes})
        (args.results / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
assert refinements, 'Qualified word refinement was never observed'
passed = all(not row['newCorrectToWrongPositions'] and row['matched'] >= row['baselineMatched']
             for row in summary['cases'])
summary['regressionStatus'] = 'PASS' if passed else 'FAIL'
summary['qualityStatus'] = 'PASS' if all(not row['missing'] and row['exactGrid'] for row in summary['cases']) else 'FAIL'
(args.results / 'summary.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
print(json.dumps(summary, ensure_ascii=False, indent=2))
raise SystemExit(0 if passed else 1)
