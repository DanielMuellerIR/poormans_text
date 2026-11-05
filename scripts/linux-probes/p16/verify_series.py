#!/usr/bin/env python3
"""Begrenzte echte CLI-Neustartserie; eigene Quellen, Subreaper und pidfd-Cleanup."""
import argparse, collections, ctypes, hashlib, json, os, select, shutil, signal
import subprocess, time, zipfile
from pathlib import Path


def sha(p):
    return hashlib.sha256(p.read_bytes()).hexdigest()


def snapshot(root):
    return {str(p.relative_to(root)): {'sha256': sha(p), 'bytes': p.stat().st_size,
            'inode': p.stat().st_ino, 'mode': p.stat().st_mode & 0o777,
            'mtimeNs': p.stat().st_mtime_ns} for p in sorted(root.rglob('*')) if p.is_file()}


def owned_children():
    result = set()
    for task in Path('/proc/self/task').iterdir():
        try:
            result.update(map(int, (task / 'children').read_text().split()))
        except FileNotFoundError:
            pass
    return result


def reap_and_cleanup():
    reaped = []
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            break
        if not pid:
            break
        reaped.append(pid)
    alive = []
    pins = []
    for pid in owned_children():
        try:
            fd = os.pidfd_open(pid)
            pins.append(fd)
            fields = Path(f'/proc/{pid}/stat').read_text().rsplit(')', 1)[1].split()
            if int(fields[1]) != os.getpid():
                continue
            if not select.select([fd], [], [], 0)[0]:
                alive.append(pid)
                signal.pidfd_send_signal(fd, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for fd in pins:
        if not select.select([fd], [], [], 3)[0]:
            raise RuntimeError('Owned descendant did not end after pidfd SIGKILL')
        os.close(fd)
    while True:
        try:
            pid, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            break
        if not pid:
            break
        reaped.append(pid)
    if owned_children():
        raise RuntimeError('Owned children remain after cleanup')
    return {'liveAdoptedBeforeCleanup': len(alive), 'adoptedReaped': len(reaped), 'childrenAfterCleanup': 0}


def prepare(root, repo):
    from PIL import Image, ImageDraw, ImageFont
    root.mkdir()
    wp = repo / 'Tests/PoorMansTextCoreTests/Fixtures/WordProcessing'
    for name, original in [('word.docx', 'libreoffice.docx'), ('legacy.doc', 'libreoffice.doc')]:
        shutil.copyfile(wp / original, root / name)
    shutil.copyfile(repo / 'Tests/PoorMansTextCoreTests/Fixtures/LinuxPDF/word-gaps.pdf', root / 'page.pdf')
    shutil.copyfile(repo / 'scripts/linux-probes/p13/source.mbox', root / 'mail.mbox')
    (root / 'unicode.csv').write_text('Name,Value\nALPHA,Grüße\nBETA,"quote ""yes"""\n', encoding='utf-8')
    (root / 'batch').mkdir()
    for name in ['one.csv', 'two.csv']:
        shutil.copyfile(root / 'unicode.csv', root / 'batch' / name)
    (root / 'text.rtf').write_text(r"{\rtf1\ansi\ansicpg1252 RTFMARK Gr\'fc\'dfe \u945?}", encoding='ascii')
    entries = {'[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
      '_rels/.rels': '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="r1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
      'xl/workbook.xml': '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Grüße" sheetId="1" r:id="r1"/></sheets></workbook>',
      'xl/_rels/workbook.xml.rels': '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="r1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
      'xl/worksheets/sheet1.xml': '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>HEADER</t></is></c><c r="B1" t="inlineStr"><is><t>VALUE</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>Grüße</t></is></c><c r="B2"><v>42</v></c></row></sheetData></worksheet>'}
    with zipfile.ZipFile(root / 'sheet.xlsx', 'w', zipfile.ZIP_DEFLATED) as archive:
        for name, text in entries.items():
            archive.writestr(name, text)
    fontpath = next(p for p in [Path('/usr/share/fonts/TTF/DejaVuSans.ttf'), Path('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')] if p.is_file())
    image = Image.new('RGB', (1500, 450), 'white')
    ImageDraw.Draw(image).text((70, 140), 'FRAMEONETOKEN 1234', fill='black', font=ImageFont.truetype(str(fontpath), 64))
    image.save(root / 'image.png')
    for extension in ['csv', 'docx', 'xlsx', 'mbox', 'png', 'pdf', 'rtf', 'doc']:
        (root / ('broken.' + extension)).write_bytes(b'\xffINVALID SOURCE\x00')
    for path in root.rglob('*'):
        if path.is_file():
            path.chmod(0o444)


def safe_file(base, name):
    relative = Path(name)
    if relative.is_absolute() or '..' in relative.parts:
        raise ValueError('Unsafe report path')
    path = base / relative
    if path.is_symlink() or not path.resolve().is_relative_to(base.resolve()):
        raise ValueError('Report file escapes output')
    return path


def leaves(obj):
    if 'results' in obj:
        for entry in obj['results']:
            yield from leaves(entry)
    else:
        yield obj


def validate(obj, expected_source_hashes):
    outputs, maps, manifests = [], 0, 0
    for result in leaves(obj):
        base = Path(result['outputDirectory'])
        report = json.loads(Path(result['reportFile']).read_text())
        source = report['source']
        if (source['sha256'], source['byteCount']) not in expected_source_hashes:
            raise ValueError('Report source identity mismatch')
        for item in report['outputs']:
            path = safe_file(base, item['path'])
            if sha(path) != item['sha256'] or path.stat().st_size != item['byteCount']:
                raise ValueError('Output manifest hash or size mismatch')
            outputs.append({'path': item['path'], 'sha256': item['sha256'], 'bytes': item['byteCount']})
            if path.suffix == '.md':
                path.read_bytes().decode('utf-8')
        manifests += 1
        for mapping in report['sourceMappings']:
            output = mapping['output']
            data = safe_file(base, output['file']).read_bytes()
            start, length = output['utf8Offset'], output['utf8Length']
            if type(start) is not int or type(length) is not int or min(start, length) < 0 or start + length > len(data):
                raise ValueError('Source mapping outside output bytes')
            data[:start].decode('utf-8')
            data[start:start + length].decode('utf-8')
            data[start + length:].decode('utf-8')
            maps += 1
    return {'manifestCount': manifests, 'mappingCount': maps, 'outputs': outputs}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ['cli', 'repo', 'pandoc', 'root']:
        parser.add_argument('--' + arg, required=True, type=Path)
    args = parser.parse_args()
    cli, repo, pandoc = [getattr(args, x).resolve(strict=True) for x in ['cli', 'repo', 'pandoc']]
    root = args.root.absolute()
    root.mkdir(mode=0o700)
    root = root.resolve()
    sources = root / 'sources'
    prepare(sources, repo)
    baseline = snapshot(sources)
    hashes = {(x['sha256'], x['bytes']) for x in baseline.values()}
    (root / 'outputs').mkdir()
    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno(), 'PR_SET_CHILD_SUBREAPER failed')
    os.close(os.pidfd_open(os.getpid()))
    formats = [('csv', 'unicode.csv'), ('docx', 'word.docx'), ('xlsx', 'sheet.xlsx'), ('mbox', 'mail.mbox'),
               ('png', 'image.png'), ('pdf', 'page.pdf'), ('rtf', 'text.rtf'), ('doc', 'legacy.doc')]
    sequence = []
    for round_no in range(5):
        for extension, filename in formats:
            extra = []
            if round_no == 1:
                extra += ['--frontmatter']
            if round_no == 2:
                extra += ['--textbundle']
            if round_no == 3:
                extra += ['--progress', '--jobs', '4']
            if extension == 'png':
                extra += ['--image-ocr', 'on' if round_no in [1, 3, 4] else 'off', '--ocr-language', 'en']
            elif extension == 'pdf':
                extra += ['--pdf-ocr', 'always' if round_no == 4 else 'auto' if round_no == 3 else 'off', '--ocr-language', 'en']
            elif extension == 'xlsx' and round_no == 4:
                extra += ['--spreadsheet-format', 'tsv']
            elif extension == 'docx':
                extra += ['--docx-changes', ['accept', 'reject', 'mark', 'accept', 'reject'][round_no]]
            filename = 'batch' if extension == 'csv' and round_no == 3 else filename
            sequence.append((f'{round_no}-{extension}', filename, extra, 0))
        for extension in ['csv', 'docx', 'xlsx', 'mbox', 'png', 'pdf', 'rtf', 'doc'][round_no*2:round_no*2+2]:
            sequence.append((f'negative-{extension}', 'broken.' + extension, [], 65))
    result = {'scope': 'Real CLI restart series; no stubs, GUI, Fastra or hardware-equivalence claim.',
              'fixtures': baseline, 'cases': [], 'failures': [], 'aborted': False}
    repeated = collections.Counter()
    started = time.monotonic()
    try:
        for name, filename, options, expected in sequence:
            remaining = 180 - (time.monotonic() - started)
            if remaining <= 0:
                result['aborted'] = True
                result['failures'].append({'case': name, 'check': 'global180s'})
                break
            target = root / 'outputs' / name
            if '--textbundle' in options:
                target = target.with_suffix('.textbundle')
            out, err = root / (name + '.stdout.json'), root / (name + '.stderr.txt')
            command = [str(cli), '--json', '--report', '--source-map', '--pandoc', str(pandoc),
                       *options, '--output', str(target), '--', str(sources / filename)]
            runtime = None
            tick = time.monotonic()
            with out.open('xb') as stdout, err.open('xb') as stderr:
                child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr)
                try:
                    deadline = tick + min(15, remaining)
                    while child.poll() is None:
                        if runtime is None:
                            try:
                                path = Path(f'/proc/{child.pid}/exe')
                                if Path(os.readlink(path)).name == 'poormans-text':
                                    runtime = sha(path)
                            except OSError:
                                pass
                        if time.monotonic() >= deadline:
                            child.kill()
                            break
                        time.sleep(.005)
                    status = child.wait()
                finally:
                    if child.poll() is None:
                        child.kill()
                        child.wait()
            cleanup = reap_and_cleanup()
            record = {'case': name, 'format': filename.rsplit('.', 1)[-1], 'options': options,
                      'exit': status, 'expected': expected, 'seconds': round(time.monotonic() - tick, 3),
                      'runtimeSHA256': runtime, 'cleanup': cleanup, 'checks': {}, 'analysis': None}
            checks = record['checks']
            checks['expectedExit'] = status == expected
            checks['sourceIdentityUnchanged'] = snapshot(sources) == baseline
            checks['noLiveOwnedDescendants'] = cleanup['liveAdoptedBeforeCleanup'] == 0
            try:
                response = json.loads(out.read_text())
                record['version'] = response.get('version')
                checks['version0.41.10'] = response.get('version') == '0.41.10'
                checks['expectedJSON'] = response.get('ok') is (expected == 0)
                if expected == 0:
                    record['analysis'] = validate(response, hashes)
                    checks['manifestAndUTF8Mappings'] = True
                    markdown_paths = set()
                    for entry in leaves(response):
                        markdown_paths.add(Path(entry['markdownFile']))
                        markdown_paths.update(Path(document['markdownFile']) for document in entry.get('documents', []))
                    md = ' '.join(path.read_text() for path in sorted(markdown_paths))
                    markers = {'csv': ['ALPHA', 'Grüße', 'BETA'], 'docx': ['Äpfel', 'Grüße'],
                               'xlsx': ['HEADER', 'Grüße', '42'], 'mbox': ['First café', 'Second message'],
                               'rtf': ['RTFMARK', 'Grüße', 'α'], 'doc': ['Äpfel', 'Grüße']}
                    extension = 'csv' if filename == 'batch' else filename.rsplit('.', 1)[-1]
                    for marker in markers.get(extension, []):
                        checks['text:' + marker] = marker in md
                    if extension == 'png' and '--image-ocr' in options and options[options.index('--image-ocr') + 1] == 'on':
                        checks['OCRMarker'] = 'FRAMEONETOKEN' in md and '1234' in md
                else:
                    checks['noPublishedOutput'] = not target.exists()
                    checks['noStaging'] = not list((root / 'outputs').glob('.poormans-text-*'))
            except Exception as error:
                checks['manifestAndUTF8Mappings'] = False
                record['analysisError'] = str(error)
            result['cases'].append(record)
            for key, passed in checks.items():
                if not passed:
                    result['failures'].append({'case': name, 'check': key})
                    repeated[key] += 1
            print(name, status, round(time.monotonic() - tick, 3), [k for k,v in checks.items() if not v], flush=True)
            (root / 'evidence.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
            if any(count >= 2 for count in repeated.values()):
                result['aborted'] = True
                break
    finally:
        result['finalCleanup'] = reap_and_cleanup()
        libc.prctl(36, 0, 0, 0, 0)
    result['seconds'] = round(time.monotonic() - started, 3)
    identities = {case['runtimeSHA256'] for case in result['cases']}
    result['uniformRuntimeSHA256'] = len(identities) == 1 and None not in identities
    if not result['uniformRuntimeSHA256']:
        result['failures'].append({'case': 'series', 'check': 'uniformRuntimeSHA256'})
    result['allPassed'] = not result['failures'] and len(result['cases']) == 48
    (root / 'evidence.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(root, 'allPassed=',result['allPassed'], 'cases=',len(result['cases']), 'seconds=',result['seconds'])
    raise SystemExit(0 if result['allPassed'] else 1)


if __name__ == '__main__':
    main()
