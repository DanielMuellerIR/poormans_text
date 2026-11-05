#!/usr/bin/env python3
"""Echte ENEX-PDF-Anhänge: Originalbytes, Fehlercodes und Publikationsgrenzen."""
import argparse
import base64
import hashlib
import json
from pathlib import Path
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--cli', type=Path, required=True)
p.add_argument('--repo', type=Path, required=True)
p.add_argument('--root', type=Path, required=True)
p.add_argument('--missing-backend', action='store_true')
a = p.parse_args()
a.root.mkdir(mode=0o700)
pdf = (a.repo / 'Tests/PoorMansTextCoreTests/Fixtures/LinuxPDF/word-gaps.pdf').read_bytes()
records = []
sha = lambda data: hashlib.sha256(data).hexdigest()


def check(name, data, expected):
    source = a.root / (name + '.enex')
    digest = hashlib.md5(data).hexdigest()  # Nur ENML-Ressourcenzuordnung.
    source.write_text('<en-export><note><title>PDF reference</title><content><![CDATA['
                      '<en-note>ATTACHMENT_ALPHA Grüße<en-media type="application/pdf" hash="' + digest + '"/>'
                      'ATTACHMENT_OMEGA</en-note>]]></content><resource><data encoding="base64">' +
                      base64.b64encode(data).decode() + '</data><mime>application/pdf</mime>'
                      '<resource-attributes><file-name>reference.pdf</file-name></resource-attributes>'
                      '</resource></note></en-export>')
    original = source.read_bytes()
    output = a.root / (name + '-out')
    run = subprocess.run([str(a.cli), '--json', '--report', '--source-map', '--output', str(output), '--', str(source)],
                         capture_output=True, text=True, timeout=45)
    response = json.loads(run.stdout)
    rec = dict(case=name, expectedExit=expected, actualExit=run.returncode, sourceSHA256=sha(original), response=response)
    records.append(rec)
    assert source.read_bytes() == original
    assert run.returncode == expected and response['ok'] == (expected == 0), rec
    assert output.exists() == (expected == 0), rec
    if expected == 0:
        entries = response['outputFiles']
        for item in entries:
            content = (output / item['path']).read_bytes()
            assert len(content) == item['byteCount'] and sha(content) == item['sha256']
        attachments = [output / item['path'] for item in entries if item['path'].endswith('.pdf')]
        assert len(attachments) == 1 and attachments[0].read_bytes() == data
        markdown = Path(response['documents'][0]['markdownFile']).read_text()
        assert 'ATTACHMENT_ALPHA' in markdown.replace('\\_', '_') and 'Grüße' in markdown
        assert 'ATTACHMENT_OMEGA' in markdown.replace('\\_', '_') and 'resource-000001.pdf' in markdown
        rec['attachmentSHA256'] = sha(data)
    assert not list(a.root.glob('.poormans-text-*.tmp'))
    rec['passed'] = True


try:
    if a.missing_backend:
        check('missing-backend', pdf, 69)
    else:
        check('normal', pdf, 0)
        plain = a.root / 'plain.pdf'
        encrypted = a.root / 'encrypted.pdf'
        plain.write_bytes(pdf)
        subprocess.run(['qpdf', '--encrypt', 'synthetic-reader', 'synthetic-owner', '256', '--', str(plain), str(encrypted)],
                       check=True, capture_output=True, timeout=15)
        check('encrypted', encrypted.read_bytes(), 0)
        check('damaged', b'%PDF-1.4\nnot a valid document\n', 65)
        check('wrong-type', b'not a PDF', 65)
finally:
    (a.root / 'result.json').write_text(json.dumps(dict(cliSHA256=sha(a.cli.read_bytes()), cases=records), ensure_ascii=False, indent=2) + '\n')
print(json.dumps(dict(passed=len(records), result=str(a.root / 'result.json'))))
