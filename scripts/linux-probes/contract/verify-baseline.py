#!/usr/bin/env python3
import json,pathlib,hashlib,zipfile,sys,xml.etree.ElementTree as ET
root=pathlib.Path(__file__).resolve().parent
records=json.loads((root/'mac-baseline.json').read_text())
count=0
for name,case in records['cases'].items():
    if 'report' not in case: continue
    assert case['exit']==0 and case['sourceUnchanged'],name
    assert all(case['expectedMarkersPresent'].values()),name
    report=case['report']; assert report['schemaVersion']==1
    assert report['source']['sha256']==case['sourceSHA256'],name
    for output in report['outputs']:
        actual=case['tree'][output['path']]
        assert actual['sha256']==output['sha256'] and actual['bytes']==output['byteCount'],(name,output)
    for mapping in report['sourceMappings']:
        location=mapping['output']; data=case['markdown'][location['file']].encode()
        start=location['utf8Offset']; end=start+location['utf8Length']
        assert 0<=start<=end<=len(data);data[start:end].decode()
    count+=1
# Die Quelle/Erwartung ist vom Markdown-Ausgabegenerator unabhängig.
repo=pathlib.Path(sys.argv[1]) if len(sys.argv)>1 else pathlib.Path.cwd()
fixture=repo/'Tests/PoorMansTextCoreTests/Fixtures/WordProcessing'
case=records['cases']['picture.docx'];text='\n'.join(case['markdown'].values())
for marker in ['Fixture heading ä','bold text','italic text','First list item','Second list item','Äpfel','12','Birnen','7','Footnote content remains readable.','Final paragraph: Grüße aus Köln.','images/image01.png']:
    assert marker in text,marker
png=hashlib.sha256((fixture/'fixture.png').read_bytes()).hexdigest()
assert case['tree']['images/image01.png']['sha256']==png
with zipfile.ZipFile(fixture/'pandoc.docx') as archive:
    xml=ET.fromstring(archive.read('word/document.xml'))
    ns={'w':'http://schemas.openxmlformats.org/wordprocessingml/2006/main'}
    assert len(xml.findall('.//w:tbl/w:tr',ns))==3
    assert len(xml.findall('.//w:drawing',ns))==1
    assert len(xml.findall('.//w:numPr',ns))==2
for name,case in records['cases'].items():
    if 'expectedExit' in case:
        expected=64 if name=='collection-stdout' else case['expectedExit']
        assert case['exit']==expected,(name,case['exit'],expected)
assert records['cases']['cancel']['exit']==130
assert records['cases']['cancel']['outputPublished'] is False
assert records['fixtureCleanup']
print(f'PASS: {count} reale Mac-Konvertierungen, Report-Hashes/Quellhashes/UTF8-Bereiche, DOCX Tabellen-/Listen-/Bildbestand und PNG-Byteidentität; Fehlercodes/Abbruch/Temp-Cleanup.')
print('Grenze: Mac-Binary nicht neu gebaut; vollständiger semantischer Vergleich aller Formate und Kindprozess-Cleanup offen.')
