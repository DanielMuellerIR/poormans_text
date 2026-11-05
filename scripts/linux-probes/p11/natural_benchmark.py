#!/usr/bin/env python3
"""Sechs echte CLI-Läufe gegen fixierte natürliche PDFs; keine Downloads/Modelle."""
import argparse
import collections
import hashlib
import html.parser
import json
import os
from pathlib import Path
import re
import subprocess
import time
import unicodedata


class HTML(html.parser.HTMLParser):
    def __init__(self):
        super().__init__()
        self.text, self.cells, self.active = [], [], None

    def handle_starttag(self, tag, attrs):
        if tag in ('td', 'th'):
            self.active = {'attrs': dict(attrs), 'text': ''}

    def handle_data(self, data):
        self.text.append(data)
        if self.active is not None:
            self.active['text'] += data

    def handle_endtag(self, tag):
        if tag in ('td', 'th') and self.active is not None:
            self.cells.append(self.active)
            self.active = None


def sha(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        while chunk := stream.read(65536):
            digest.update(chunk)
    return digest.hexdigest()


def tokens(text):
    return re.findall(r'\w+', text.casefold())


def findseq(haystack, needle):
    if not needle:
        return None
    return next((i for i in range(len(haystack) - len(needle) + 1)
                 if haystack[i:i + len(needle)] == needle), None)


def diff(expected, actual):
    a, b = collections.Counter(tokens(expected)), collections.Counter(tokens(actual))
    return {'expected': sum(a.values()), 'actual': sum(b.values()), 'matched': sum((a & b).values()),
            'missing': dict(a - b), 'extra': dict(b - a)}


def body(markdown):
    # Nur Originalseiteninhalt: erzeugte Titel, Anker, Assetlinks und Anhänge ausschließen.
    text = markdown.split('## Page 1\n\n', 1)[1]
    text = re.split(r'\n\n(?:!\[PDF image\]|### (?:Links|Annotations))', text, maxsplit=1)[0]
    text = re.sub(r'\\([!"#$%&\'()*+,\-./:;<=>?@\[\]\\^_`{|}~])', r'\1', text)
    uncertain = re.findall(r'\[OCR uncertain: ([^\]]*)\]', text)
    text = re.sub(r'\[OCR uncertain: ([^\]]*)\]', r'\1', text)
    return text, uncertain


def compare(record, text):
    output = tokens(text)
    expected, elements, cells = [], [], []
    for index, element in enumerate(record['elements']):
        content = element['content']
        value = content['text']
        if element['category'] == 'Table':
            parser = HTML()
            parser.feed(content['html'])
            value = ' '.join(parser.text)
            # Im gewählten Originalrecord steht nach der einzigen Tabelle deren Caption.
            # Spätere Wiederholungen im Fließtext dürfen keine fehlende Zelle kompensieren.
            following = record['elements'][index + 1]
            if following['category'] != 'Caption':
                raise ValueError('Unsupported table scope in fixed reference')
            end = findseq(output, tokens(following['content']['text'])[:8])
            if end is None:
                raise ValueError('Following table caption not found; cell comparison unavailable')
            table_tokens = output[:end]
            table_text = text.split(following['content']['text'].split(':', 1)[0], 1)[0]
            for cell in parser.cells:
                offset = findseq(table_tokens, tokens(cell['text']))
                cells.append({'text': cell['text'], 'rowspan': int(cell['attrs'].get('rowspan', 1)),
                              'colspan': int(cell['attrs'].get('colspan', 1)), 'tokenOffset': offset,
                              'exactTokenSequenceFound': offset is not None,
                              'substringFound': ' '.join(cell['text'].split()) in ' '.join(table_text.split())})
        if value:
            expected.append(value)
        sequence = tokens(value)
        anchor = sequence[:8]
        elements.append({'id': element['id'], 'category': element['category'], 'anchor': anchor,
                         'anchorOffset': findseq(output, anchor),
                         'entireElementContiguous': findseq(output, sequence) is not None})
    positions = [e['anchorOffset'] for e in elements if e['anchorOffset'] is not None]
    cell_positions = [c['tokenOffset'] for c in cells if c['tokenOffset'] is not None]
    original = ' '.join(expected)
    return {'wordInventory': diff(original, text),
            'nfkcVariantNotPrimary': diff(unicodedata.normalize('NFKC', original), unicodedata.normalize('NFKC', text)),
            'elements': elements, 'foundAnchorsInGTOrder': positions == sorted(positions),
            'cells': cells, 'foundCellsInGTOrder': cell_positions == sorted(cell_positions),
            'tableStructurePresent': bool(re.search(r'<table\b|\|\s*:?-{3}', text, re.I)),
            'colspanPresent': 'colspan' in text}


def execute(command, stdout_path, stderr_path, expected_name):
    runtime = None
    started = time.monotonic()
    reason = None
    with stdout_path.open('xb') as stdout, stderr_path.open('xb') as stderr:
        child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
        try:
            while child.poll() is None:
                if runtime is None:
                    try:
                        executable = Path(os.readlink('/proc/' + str(child.pid) + '/exe'))
                        if executable.name in (expected_name, 'poormans-text'):
                            runtime = {'name': executable.name, 'sha256': sha(Path('/proc/' + str(child.pid) + '/exe'))}
                    except OSError:
                        pass  # Auf Systemen ohne /proc bleibt der konkrete ELF-Hash unbekannt.
                if time.monotonic() - started >= 120:
                    reason = 'timeout'
                elif stdout_path.stat().st_size > 16 * 1024**2 or stderr_path.stat().st_size > 2 * 1024**2:
                    reason = 'captureLimit'
                if reason:
                    child.kill()  # Nur das eigene, noch ungeerntete Child; Swift besitzt seinen Namespace-Cleanup.
                    child.wait()
                    break
                time.sleep(.02)
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
    return child.returncode, round(time.monotonic() - started, 3), reason, runtime


def analyze_case(destination, source, record, stdout_path):
    result = json.loads(stdout_path.read_text())
    if result.get('ok') is not True:
        raise ValueError('CLI JSON did not report success')
    report = json.loads((destination / 'conversion-report.json').read_text())
    checks = []
    for item in report['outputs']:
        relative = Path(item['path'])
        if relative.is_absolute() or '..' in relative.parts:
            raise ValueError('Unsafe report output path')
        target = destination / relative
        if target.is_symlink() or not target.resolve().is_relative_to(destination.resolve()):
            raise ValueError('Report output leaves its directory')
        checks.append({'path': item['path'], 'bytes': target.stat().st_size, 'sha256': sha(target),
                       'matches': target.stat().st_size == item['byteCount'] and sha(target) == item['sha256']})
    markdowns = [item for item in report['outputs'] if item['path'].endswith('.md')]
    if len(markdowns) != 1:
        raise ValueError('Expected exactly one Markdown output')
    text, uncertain = body((destination / markdowns[0]['path']).read_text())
    analysis = compare(record, text)
    source_identity = report['source']
    analysis.update({'version': report['converterVersion'], 'outputs': checks,
                     'reportSourceMatches': source_identity['sha256'] == sha(source) and source_identity['byteCount'] == source.stat().st_size,
                     'assetCount': len(result['assets']), 'uncertainOCRPayloads': uncertain,
                     'diagnosticCodes': [d['code'] for d in result.get('diagnostics', [])]})
    return analysis


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cli', required=True, type=Path)
    parser.add_argument('--corpus', required=True, type=Path)
    parser.add_argument('--root', required=True, type=Path, help='New result directory; must not exist')
    args = parser.parse_args()
    cli, corpus = args.cli.expanduser().resolve(strict=True), args.corpus.expanduser().resolve(strict=True)
    root = args.root.expanduser().absolute()
    evidence = Path(__file__).resolve().parents[3] / 'docs/linux-port/P11-NATURAL-EVIDENCE'
    manifest = json.loads((evidence / 'manifest.json').read_text())
    reference_path = evidence / manifest['selectedAnnotations']
    if sha(reference_path) != manifest['selectedAnnotationsSHA256']:
        raise ValueError('Selected reference SHA256 mismatch')
    records = json.loads(reference_path.read_text())
    for item in manifest['documents']:
        source = corpus / item['name']
        if source.stat().st_size != item['bytes'] or sha(source) != item['sha256']:
            raise ValueError('Corpus identity mismatch: ' + item['name'])
    root.mkdir(mode=0o700)
    root = root.resolve()
    summary = {'cliName': cli.name, 'cliFileSHA256': sha(cli), 'datasetRevision': manifest['revision'],
               'tokenization': 'Unicode w+ and casefold; no accent removal, dehyphenation or word-boundary repair. Generated Markdown/attachment syntax and OCR uncertainty label excluded; uncertain payload retained.',
               'cases': []}
    failed = False
    for item in manifest['documents']:
        source = corpus / item['name']
        for mode in ('off', 'always'):
            name = source.stem + '-' + mode
            destination = root / name
            stdout, stderr = root / (name + '.stdout.json'), root / (name + '.stderr.txt')
            command = [str(cli), '--json', '--report', '--pdf-ocr', mode, '--ocr-method', 'standard',
                       '--ocr-language', 'en', '-o', str(destination), '--', str(source)]
            status, elapsed, reason, runtime = execute(command, stdout, stderr, cli.name)
            case = {'source': source.name, 'mode': mode, 'exit': status, 'seconds': elapsed,
                    'stopReason': reason, 'executedBinary': runtime, 'sourceSHA256': sha(source),
                    'sourceUnchanged': sha(source) == item['sha256']}
            try:
                if status != 0 or reason:
                    raise ValueError('CLI failed or exceeded its limits')
                case['analysis'] = analyze_case(destination, source, records[source.name], stdout)
                case['integrityPassed'] = case['sourceUnchanged'] and case['analysis']['reportSourceMatches'] and all(x['matches'] for x in case['analysis']['outputs'])
                failed |= not case['integrityPassed']
            except Exception as error:
                case['analysisError'] = type(error).__name__ + ': ' + str(error)
                failed = True
            summary['cases'].append(case)
            (root / 'evidence.json').write_text(json.dumps(summary, ensure_ascii=False, indent=2) + '\n')
            print(name, status, elapsed, flush=True)
    print(root)
    raise SystemExit(1 if failed else 0)


if __name__ == '__main__':
    main()
