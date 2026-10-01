#!/usr/bin/env python3
"""Vergleicht ZIP-Erkennung an identischen temporären ODT-Paketen, ohne App-Start."""
import argparse
import hashlib,json,os,re,statistics,struct,subprocess,time,zlib
from pathlib import Path
PROBE_SOURCE = r'''
import Foundation
let source = URL(fileURLWithPath: CommandLine.arguments[1])
let started = Date()
let reader = try ZIPArchiveInspector.inspectionSnapshot(at: source)
let contents = try reader.contents(entryNames: ["mimetype", "content.xml"])
let format = try WordProcessingPackageInspector.inspect(reader: reader)?.format.rawValue ?? "none"
let metadata = contents.entries.keys.sorted().map { name in
    "\(name):\(contents.entries[name]!.base64EncodedString())"
}.joined(separator: "|")
print("\(format)|\(contents.entryNames.sorted().joined(separator: ","))|\(metadata)")
fputs("\(Date().timeIntervalSince(started)) seconds inspection\n", stderr)
'''

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--baseline', required=True, help='Git-Revision vor der Änderung')
parser.add_argument('--root', required=True, type=Path, help='Neuer temporärer Messordner')
args = parser.parse_args()
repo = Path(__file__).resolve().parents[1]
root = args.root.resolve()
root.mkdir(parents=True, exist_ok=False)
baseline = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', '--verify', args.baseline + '^{commit}'], text=True).strip()
probe_source = root / 'main.swift'
probe_source.write_text(PROBE_SOURCE)
source_manifests = {}
for version in ['before', 'after']:
    if version == 'before':
        source_root = root / 'before-source'
        source_root.mkdir()
        names = subprocess.check_output(['git', '-C', str(repo), 'ls-tree', '-r', '--name-only', baseline, 'Sources/PoorMansTextCore'], text=True).splitlines()
        sources = []
        for name in names:
            if not name.endswith('.swift'): continue
            target = source_root / Path(name).name
            target.write_bytes(subprocess.check_output(['git', '-C', str(repo), 'show', baseline + ':' + name]))
            sources.append(str(target))
    else:
        source_root = root / 'after-source'
        source_root.mkdir()
        sources = []
        for source in sorted((repo / 'Sources/PoorMansTextCore').glob('*.swift')):
            target = source_root / source.name
            target.write_bytes(source.read_bytes())
            sources.append(str(target))
    source_manifests[version] = {Path(source).name: hashlib.sha256(Path(source).read_bytes()).hexdigest() for source in sources}
    command = ['swiftc', '-O', '-swift-version', '6', '-package-name', 'poormans_text', *sources, str(probe_source), '-o', str(root / (version + '-probe'))]
    with (root / ('compile-' + version + '.log')).open('w') as log:
        subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=300)
xml=b'''<?xml version="1.0"?><office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0"><office:body><office:text><text:p>ZIP bounded inspection fixture</text:p></office:text></office:body></office:document-content>'''
def checksum_zeros(size):
    crc=0; chunk=bytes(1024*1024)
    for offset in range(0,size,len(chunk)):crc=zlib.crc32(chunk[:min(size-offset,len(chunk))],crc)
    return crc
def fixture(size):
    target=root/f'stored-{size//(1024*1024)}MiB.odt'
    central=[]
    with target.open('wb') as f:
        for name,payload,length,crc in [(b'mimetype',b'application/vnd.oasis.opendocument.text',len(b'application/vnd.oasis.opendocument.text'),zlib.crc32(b'application/vnd.oasis.opendocument.text')),(b'content.xml',xml,len(xml),zlib.crc32(xml)),(b'ballast.bin',None,size,checksum_zeros(size))]:
            offset=f.tell()
            f.write(struct.pack('<IHHHHHIIIHH',0x04034b50,20,0,0,0,0,crc,length,length,len(name),0));f.write(name)
            if payload is None:f.seek(length,os.SEEK_CUR)
            else:f.write(payload)
            central.append(struct.pack('<IHHHHHHIIIHHHHHII',0x02014b50,20,20,0,0,0,0,crc,length,length,len(name),0,0,0,0,0,offset)+name)
        offset=f.tell();directory=b''.join(central);f.write(directory)
        f.write(struct.pack('<IHHHHIIH',0x06054b50,0,0,3,3,len(directory),offset,0))
    return target
def sha(path):
    h=hashlib.sha256()
    with path.open('rb') as f:
        while b:=f.read(1024*1024):h.update(b)
    return h.hexdigest()
results=[]
for size in [1024*1024,256*1024*1024,768*1024*1024]:
    target=fixture(size);original=sha(target);runs={'before':[],'after':[]};expected=None
    for repeat in range(3):
        for version in ['before','after']:
            start=time.monotonic()
            run=subprocess.run(['/usr/bin/time','-l',str(root/f'{version}-probe'),str(target)],capture_output=True,text=True,timeout=120)
            if run.returncode:raise RuntimeError(run.stderr)
            if expected is None:expected=run.stdout
            assert run.stdout==expected,(version,target)
            rss=int(re.search(r'(\d+)\s+maximum resident set size',run.stderr)[1])
            seconds=float(re.search(r'([\d.]+) seconds inspection',run.stderr)[1])
            runs[version].append({'rss_bytes':rss,'inspection_seconds':seconds,'wall_seconds':time.monotonic()-start})
    assert sha(target)==original
    result={'fixture':target.name,'archive_bytes':target.stat().st_size,'sha256':original,'output_sha256':hashlib.sha256(expected.encode()).hexdigest(),'runs':runs}
    for version in runs:result[version]={'maximum_rss_bytes':max(r['rss_bytes'] for r in runs[version]),'median_inspection_seconds':statistics.median(r['inspection_seconds'] for r in runs[version]),'median_wall_seconds':statistics.median(r['wall_seconds'] for r in runs[version])}
    results.append(result);print(json.dumps(result),flush=True)
(root/'benchmark.json').write_text(json.dumps({'baseline':baseline,'source_manifests':source_manifests,'results':results},indent=2)+'\n')
