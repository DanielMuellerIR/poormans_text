"""P06 real CLI integration; fixtures are generated locally, no product stubs."""
import argparse, base64, hashlib, http.server, json, pathlib, plistlib, re, shutil, subprocess, tempfile, threading, time, zipfile
P = pathlib.Path

def sha(data):
    return hashlib.sha256(data).hexdigest()

def fingerprint(path):
    if path.is_file():
        return sha(path.read_bytes())
    return sha(json.dumps([(str(p.relative_to(path)), sha(p.read_bytes())) for p in sorted(path.rglob('*')) if p.is_file()]).encode())

def fixtures(root, repo, url):
    root.mkdir()
    png = (repo / 'Tests/PoorMansTextCoreTests/Fixtures/WordProcessing/fixture.png').read_bytes()
    (root / 'picture.png').write_bytes(png)
    (root.parent / 'outside.png').write_bytes(png)
    original = repo / 'Tests/PoorMansTextCoreTests/Fixtures/WordProcessing'
    for name in ['pandoc.docx', 'pandoc.odt', 'annotated.docx', 'external-image.docx', 'external-image.odt', 'unsafe-path.docx']:
        shutil.copyfile(original / name, root / name)
    with zipfile.ZipFile(root / 'annotated.docx') as src, zipfile.ZipFile(root / 'review.docx', 'w', zipfile.ZIP_DEFLATED) as dst:
        for item in src.infolist():
            content = src.read(item.filename)
            if item.filename == 'word/document.xml':
                content = content.replace(b'<w:ins w:id="1"', b'<w:del w:id="2" w:author="Fixture"><w:r><w:delText>Rejected change</w:delText></w:r></w:del><w:ins w:id="1"')
            dst.writestr(item.filename, content)
    variants = {'docm': 'application/vnd.ms-word.document.macroEnabled.main+xml', 'dotx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.template.main+xml', 'dotm': 'application/vnd.ms-word.template.macroEnabledTemplate.main+xml'}
    for ext, kind in variants.items():
        with zipfile.ZipFile(original / 'pandoc.docx') as src, zipfile.ZipFile(root / ('variant.' + ext), 'w', zipfile.ZIP_DEFLATED) as dst:
            for item in src.infolist():
                content = src.read(item.filename)
                if item.filename == '[Content_Types].xml':
                    content = content.replace(b'application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml', kind.encode())
                dst.writestr(item.filename, content)
    text = {'encoding.rtf': "{\\rtf1\\ansi\\ansicpg1252 Gr\\'fc\\'dfe \\u945?}", 'notes.org': '* ORGTOKEN\n\nText with *bold*.\n[[file:picture.png]]\n', 'safe.tex': '\\documentclass{article}\\begin{document}\\section{LATEXTOKEN}Text with \\textbf{bold}.\\end{document}', 'book.dbk': '<?xml version="1.0"?><book xmlns="http://docbook.org/ns/docbook"><title>DOCBOOKTOKEN</title><chapter><title>Part</title><para>Text with <emphasis role="bold">bold</emphasis>.</para></chapter></book>', 'page.wiki': "== WIKITOKEN ==\n\nText with '''bold'''.\n", 'page.textile': 'h1. TEXTILETOKEN\n\nText with *bold*.\n', 'page.rst': 'RSTTOKEN\n========\n\nText with **bold**.\n', 'source.html': f'<!DOCTYPE html><html><head><meta charset="utf-8"><title>HTMLTOKEN</title><meta name="author" content="Fixture author"></head><body><h1>HTMLTOKEN</h1><p>Grüße **literal**</p><p><img src="picture.png" alt="Local"/></p><p><img src="data:image/png;base64,{base64.b64encode(png).decode()}" alt="Embedded"/></p><p><img src="{url}/remote.png" alt="Remote"/></p><p><img src="missing.png" alt="Missing"/></p><p><img src="../outside.png" alt="Outside"/></p><script>SHOULDNOTRENDER</script></body></html>', 'secret.tex': 'SECRETSHOULDNEVERAPPEAR', 'escape.tex': '\\documentclass{article}\\begin{document}VISIBLE\\input{secret.tex}\\end{document}', 'bad.rtf': 'not RTF', '-dash: ü.org': '* DASHTOKEN\n\nBody.\n'}
    for name, content in text.items():
        (root / name).write_text(content)
    archive = {'WebMainResource': {'WebResourceData': b'<html><head><title>ARCHIVETOKEN</title></head><body><p>ARCHIVETOKEN</p><img src="https://fixture.invalid/image.png" alt="Archived"/></body></html>', 'WebResourceMIMEType': 'text/html', 'WebResourceURL': 'https://fixture.invalid/page.html', 'WebResourceTextEncodingName': 'UTF-8'}, 'WebSubresources': [{'WebResourceData': png, 'WebResourceMIMEType': 'image/png', 'WebResourceURL': 'https://fixture.invalid/image.png'}]}
    (root / 'page.webarchive').write_bytes(plistlib.dumps(archive, fmt=plistlib.FMT_BINARY))
    fb2 = f'<?xml version="1.0"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0" xmlns:l="http://www.w3.org/1999/xlink"><description><title-info><book-title>FB2TOKEN</book-title><author><first-name>Test</first-name><last-name>Author</last-name></author></title-info></description><body><section><title><p>FB2TOKEN</p></title><p>Text with <strong>bold</strong>.</p><image l:href="#image.png"/></section></body><binary id="image.png" content-type="image/png">{base64.b64encode(png).decode()}</binary></FictionBook>'
    (root / 'book.fb2').write_text(fb2)
    entries = {'mimetype': 'application/epub+zip', 'META-INF/container.xml': '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/package.opf" media-type="application/oebps-package+xml"/></rootfiles></container>', 'OEBPS/package.opf': '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">proof</dc:identifier><dc:title>EPUBTOKEN</dc:title><dc:language>en</dc:language></metadata><manifest><item id="beta" href="b.xhtml" media-type="application/xhtml+xml"/><item id="alpha" href="a.xhtml" media-type="application/xhtml+xml"/><item id="gamma" href="c.xhtml" media-type="application/xhtml+xml"/><item id="image" href="picture.png" media-type="image/png"/></manifest><spine><itemref idref="beta"/><itemref idref="alpha"/><itemref idref="gamma"/></spine></package>', 'OEBPS/b.xhtml': '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>BetaMarker</title></head><body><h1 id="b">BetaMarker</h1><p><a href="c.xhtml#c">To gamma</a></p><p><img src="picture.png" alt="Picture"/></p></body></html>', 'OEBPS/a.xhtml': '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>AlphaMarker</title></head><body><h1>AlphaMarker</h1><p>Alpha body</p></body></html>', 'OEBPS/c.xhtml': '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>GammaMarker</title></head><body><h1 id="c">GammaMarker</h1><p>Gamma body</p></body></html>', 'OEBPS/picture.png': png}
    with zipfile.ZipFile(root / 'book.epub', 'w') as archive:
        for name, content in entries.items():
            archive.writestr(name, content, compress_type=zipfile.ZIP_STORED if name == 'mimetype' else zipfile.ZIP_DEFLATED)
    return png

class Probe:

    def __init__(self, args, root):
        self.args = args
        self.root = root
        self.records = []
        self.failures = []

    def check(self, record, label, condition):
        record.setdefault('checks', {})[label] = bool(condition)
        if not condition:
            self.failures.append({'case': record['name'], 'check': label})

    def run(self, name, flags, source=None, output=True, expected=0):
        command = [str(self.args.cli)] + ([] if '--list-chapters' in flags else ['--pandoc', str(self.args.pandoc)]) + flags
        target = self.root / 'outputs' / (name + ('.textbundle' if '--textbundle' in flags else ''))
        target.parent.mkdir(exist_ok=True)
        if output:
            command += ['--output', str(target)]
        if source:
            command += ['--', source.name if source.name.startswith('-') else str(source)]
        before = fingerprint(source) if source else None
        started = time.monotonic()
        try:
            result = subprocess.run(command, cwd=self.root / 'fixtures', capture_output=True, timeout=35)
        except subprocess.TimeoutExpired as e:
            record = {'name': name, 'status': 'timeout', 'args': command[1:]}
            self.records.append(record)
            self.failures.append({'case': name, 'check': '35s bounded CLI'})
            return record
        record = {'name': name, 'args': command[1:], 'exit': result.returncode, 'seconds': round(time.monotonic() - started, 4), 'stdout': result.stdout.decode('utf8'), 'stderr': result.stderr.decode('utf8')}
        self.records.append(record)
        self.check(record, 'expectedExit', result.returncode == expected)
        if source:
            self.check(record, 'sourceUnchanged', fingerprint(source) == before)
        try:
            record['json'] = json.loads(record['stdout'])
        except ValueError:
            pass
        obj = record.get('json', {})
        if obj.get('ok') and obj.get('markdownFile'):
            md = P(obj['markdownFile'])
            record['markdown'] = md.read_text()
            record['tree'] = {str(p.relative_to(P(obj['outputDirectory']))): sha(p.read_bytes()) for p in P(obj['outputDirectory']).rglob('*') if p.is_file()}
            self.check(record, 'absoluteMarkdownPath', md.is_absolute())
            self.check(record, 'assetFilesExist', all((P(p).is_file() for p in obj['assets'])))
            if obj.get('reportFile'):
                report = json.loads(P(obj['reportFile']).read_text())
                record['report'] = report
                for item in report['outputs']:
                    data = (P(obj['outputDirectory']) / item['path']).read_bytes()
                    self.check(record, 'hash:' + item['path'], sha(data) == item['sha256'] and len(data) == item['byteCount'])
                data = md.read_bytes()
                for i, mapping in enumerate(report['sourceMappings']):
                    out = mapping['output']
                    part = data[out['utf8Offset']:out['utf8Offset'] + out['utf8Length']]
                    try:
                        part.decode()
                        valid = True
                    except UnicodeDecodeError:
                        valid = False
                    self.check(record, 'mapping:' + str(i), valid and out['utf8Offset'] + out['utf8Length'] <= len(data))
        if expected != 0 and output and ('results' not in obj):
            self.check(record, 'noPublishedOutput', not target.exists())
        return record

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cli', type=P, required=True)
    parser.add_argument('--pandoc', type=P, required=True)
    parser.add_argument('--repo', type=P, required=True)
    parser.add_argument('--executable', type=P)
    parser.add_argument('--parent', type=P, default=P(tempfile.gettempdir()))
    args = parser.parse_args()
    args.cli = args.cli.resolve()
    args.pandoc = args.pandoc.resolve()
    args.repo = args.repo.resolve()
    if args.executable:
        args.executable = args.executable.resolve()
    root = P(tempfile.mkdtemp(prefix='pmt-p06-cli-', dir=args.parent))
    probe = Probe(args, root)
    requests = []

    class Handler(http.server.BaseHTTPRequestHandler):

        def do_GET(self):
            requests.append(self.path)
            self.send_response(200)
            self.end_headers()
            self.wfile.write(b'UNEXPECTEDNETWORK')

        def log_message(self, *a):
            pass
    server = http.server.HTTPServer(('127.0.0.1', 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    png = fixtures(root / 'fixtures', args.repo, f'http://127.0.0.1:{server.server_port}')
    source = root / 'fixtures'
    catalog = probe.run('catalog', ['--formats', '--json'], output=False)
    entries = {entry['format']: entry for entry in catalog.get('json', {}).get('formats', [])}
    for fmt in ['rtf', 'docx', 'odt', 'html', 'webarchive', 'epub', 'latex', 'docbook', 'org', 'mediawiki', 'textile', 'rst', 'fb2']:
        probe.check(catalog, 'available:' + fmt, entries.get(fmt, {}).get('available') is True)
    caseMarkers = {'encoding.rtf': ['Grüße', 'α'], 'pandoc.docx': ['Fixture heading ä', 'Äpfel', 'Birnen', 'Footnote content remains readable.'], 'pandoc.odt': ['Fixture heading ä', 'Äpfel', 'Birnen'], 'variant.docm': ['Fixture heading ä'], 'variant.dotx': ['Fixture heading ä'], 'variant.dotm': ['Fixture heading ä'], 'source.html': ['HTMLTOKEN', 'Grüße'], 'page.webarchive': ['ARCHIVETOKEN'], 'book.epub': ['BetaMarker', 'AlphaMarker', 'GammaMarker'], 'safe.tex': ['LATEXTOKEN', '**bold**'], 'book.dbk': ['DOCBOOKTOKEN', '**bold**'], 'notes.org': ['ORGTOKEN', '**bold**'], 'page.wiki': ['WIKITOKEN', '**bold**'], 'page.textile': ['TEXTILETOKEN', '**bold**'], 'page.rst': ['RSTTOKEN', '**bold**'], 'book.fb2': ['FB2TOKEN', '**bold**'], '-dash: ü.org': ['DASHTOKEN']}
    for i, (name, markers) in enumerate(caseMarkers.items()):
        r = probe.run('format-' + str(i), ['--json', '--progress', '--report'], source / name)
        if r.get('json', {}).get('ok'):
            for marker in markers:
                probe.check(r, 'marker:' + marker, marker in r['markdown'])
            probe.check(r, 'stderrOnlyProgress', 'Progress: ' in r['stderr'] and 'finished' in r['stderr'])
            if name in ['pandoc.docx', 'pandoc.odt', 'variant.docm', 'variant.dotx', 'variant.dotm', 'notes.org', 'page.webarchive', 'book.epub', 'book.fb2']:
                probe.check(r, 'expectedImage', len(r['json']['assets']) == 1)
                if r['json']['assets']:
                    probe.check(r, 'imageByteIdentity', P(r['json']['assets'][0]).read_bytes() == png)
            if name == 'book.dbk':
                probe.check(r, 'bookTitleMetadata', r['json'].get('metadata', {}).get('title') == 'DOCBOOKTOKEN')
            if name.startswith('variant.'):
                needed = {'docm': {'wordProcessing.macrosNotPreserved'}, 'dotx': {'wordProcessing.templateSemanticsNotPreserved'}, 'dotm': {'wordProcessing.macrosNotPreserved', 'wordProcessing.templateSemanticsNotPreserved'}}[name.split('.')[-1]]
                probe.check(r, 'macroTemplateWarnings', needed <= {d['code'] for d in r['json'].get('diagnostics', [])})
            if name == 'source.html':
                probe.check(r, 'localAndEmbeddedImages', len(r['json']['assets']) == 2)
                probe.check(r, 'remoteOnlyLink', '[Remote](http://' in r['markdown'] and '![Remote]' not in r['markdown'])
                probe.check(r, 'scriptNotRendered', 'SHOULDNOTRENDER' not in r['markdown'])
                probe.check(r, 'outsideLocalImageNotLoaded', 'outside.png' not in r['markdown'] and len(r['json']['assets']) == 2)
                probe.check(r, 'remoteAndMissingDiagnosed', any(('remote' in d['code'].lower() for d in r['json'].get('diagnostics', []))) and any(('missing' in d['code'].lower() for d in r['json'].get('diagnostics', []))))
    for mode in ['accept', 'reject', 'mark']:
        r = probe.run('review-' + mode, ['--json', '--docx-changes', mode, '--report'], source / 'review.docx')
        if r.get('json', {}).get('ok'):
            probe.check(r, 'insertionMode', ('Accepted change' in r['markdown']) == (mode != 'reject'))
            probe.check(r, 'deletionMode', ('Rejected change' in r['markdown']) == (mode != 'accept'))
            probe.check(r, 'commentRetained', 'Review note' in r['markdown'] and any((d['code'] == 'docx.commentPreserved' for d in r['json'].get('diagnostics', []))))
            probe.check(r, 'reportMode', r['report']['options']['docxChangeMode'] == mode)
    r = probe.run('epub-overview', ['--json', '--list-chapters'], source / 'book.epub', output=False)
    if 'json' in r:
        probe.check(r, 'spineOrder', [c['title'] for c in r['json'].get('chapters', [])] == ['BetaMarker', 'AlphaMarker', 'GammaMarker'])
    for layout in [[], ['--textbundle']]:
        r = probe.run('epub-selected' + str(len(layout)), ['--json', '--progress', '--report', '--epub-chapters', '3,1,1'] + layout, source / 'book.epub')
        if r.get('json', {}).get('ok'):
            text = r['markdown']
            probe.check(r, 'selectionContents', 'BetaMarker' in text and 'GammaMarker' in text and ('AlphaMarker' not in text))
            probe.check(r, 'selectionOrder', text.index('BetaMarker') < text.index('GammaMarker'))
            probe.check(r, 'originalChapterPositions', [m['source'].get('chapter') for m in r['report']['sourceMappings']] == [1, 3])
            probe.check(r, 'canonicalSelection', r['report']['options']['epubChapters'] == '1,3')
    r = probe.run('epub-excluded-link', ['--json', '--report', '--epub-chapters', '1'], source / 'book.epub')
    if r.get('json', {}).get('ok'):
        probe.check(r, 'excludedLinkRemoved', 'c.xhtml' not in r['markdown'])
        probe.check(r, 'excludedLinkDiagnosed', any((d['code'] == 'epub.linkTargetExcluded' for d in r['json'].get('diagnostics', []))))
    r = probe.run('missing-pandoc', ['--json', '--pandoc', str(root / 'no-pandoc')], source / 'encoding.rtf', expected=69)
    r = probe.run('frontmatter-textbundle', ['--json', '--textbundle', '--frontmatter'], source / 'source.html')
    if r.get('json', {}).get('ok'):
        probe.check(r, 'frontmatter', r['markdown'].startswith('---\ntitle: "HTMLTOKEN"\nauthor: "Fixture author"\n---\n'))
        probe.check(r, 'bundleFiles', r['json']['markdownFile'].endswith('/text.md') and 'info.json' in r['tree'])
        probe.check(r, 'bundleImageLinks', 'assets/image01.png' in r['markdown'])
    r = probe.run('stdout', ['--stdout'], source / 'page.rst', output=False)
    probe.check(r, 'plainMarkdownOnly', '# RSTTOKEN' in r['stdout'] and '"ok"' not in r['stdout'])
    r = probe.run('stdout-assets', ['--stdout'], source / 'pandoc.docx', output=False)
    probe.check(r, 'assetOmissionWarning', 'asset(s) were not written' in r['stderr'])
    for i, flags in enumerate([['--stdout', '--json'], ['--stdout', '--report'], ['--stdout', '--textbundle'], ['--jobs', '0', '--json'], ['--epub-chapters', '0', '--json']]):
        probe.run('usage-' + str(i), flags, source / 'page.rst', output=False, expected=64)
    for i, name in enumerate(['external-image.docx', 'external-image.odt', 'unsafe-path.docx']):
        probe.run('unsafe-' + str(i), ['--json'], source / name, expected=65)
    r = probe.run('latex-file-exfiltration', ['--json'], source / 'escape.tex')
    if r.get('json', {}).get('ok'):
        probe.check(r, 'secretBlocked', 'SECRETSHOULDNEVERAPPEAR' not in r['markdown'])
    batch = root / 'batch'
    batch.mkdir()
    (batch / 'nested').mkdir()
    for name in ['notes.org', 'page.rst', 'bad.rtf']:
        shutil.copyfile(source / name, batch / name)
    shutil.copyfile(source / 'page.wiki', batch / 'nested/page.wiki')
    r = probe.run('batch-jobs', ['--json', '--progress', '--jobs', '4'], batch, expected=65)
    if 'json' in r:
        results = r['json'].get('results', [])
        probe.check(r, 'batchContinues', len(results) == 4 and sum((bool(x['ok']) for x in results)) == 3)
        probe.check(r, 'batchErrorDidNotStopOthers', len([x for x in results if not x['ok']]) == 1)
        probe.check(r, 'jobsProgress', 'running ' in r['stderr'])
        completed = [int(m.group(1)) for m in re.finditer(r'; files (\d+)/4, running \d+', r['stderr'])]
        probe.check(r, 'monotonicBatchProgress', bool(completed) and completed == sorted(completed) and completed[-1] == 4)
        probe.check(r, 'folderStructure', any(('nested' in x.get('markdownFile', '') for x in results)))
    probe.check(probe.records[-1], 'noRemoteRequests', not requests)
    server.shutdown()
    server.server_close()
    evidence = {'productVersion': subprocess.check_output([str(args.cli), '--version'], text=True).strip(), 'cliSHA256': sha((args.executable or args.repo / '.build/linux-runtime/bin/poormans-text').read_bytes()), 'pandocVersion': subprocess.check_output([str(args.pandoc), '--version'], text=True).splitlines()[0], 'pandocSHA256': sha(args.pandoc.read_bytes()), 'runRoot': str(root), 'records': probe.records, 'failures': probe.failures, 'remoteRequests': requests}
    (root / 'evidence.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2))
    print(json.dumps({'runRoot': str(root), 'cases': len(probe.records), 'checks': sum((len(r.get('checks', {})) for r in probe.records)), 'failures': probe.failures}, ensure_ascii=False, indent=2))
    return bool(probe.failures)
if __name__ == '__main__':
    raise SystemExit(main())
