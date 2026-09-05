#!/usr/bin/env python3
"""Reproduzierbare Paketmessung auf macOS; erzeugt ausschließlich neue Testausgaben."""
from pathlib import Path
import argparse
import hashlib
import json
import os
import signal
import random
import re
import shutil
import struct
import subprocess
import zipfile
import zlib


def generate(root, pandoc):
    root.mkdir(parents=True, exist_ok=True)
    if (root / "source-hashes.json").exists() or (root / "source-hashes.json").is_symlink():
        raise FileExistsError("Source manifest already exists")
    source=root/'inputs'; source.mkdir(exist_ok=False)
    ns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'
    rel='http://schemas.openxmlformats.org/officeDocument/2006/relationships'
    with zipfile.ZipFile(source/'large.xlsx','w',compression=zipfile.ZIP_DEFLATED) as z:
     z.writestr('[Content_Types].xml','<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/></Types>')
     z.writestr('xl/workbook.xml',f'<workbook xmlns="{ns}" xmlns:r="{rel}"><sheets>'+''.join(f'<sheet name="Sheet{s}" sheetId="{s}" r:id="s{s}"/>' for s in range(1,33))+'</sheets></workbook>')
     z.writestr('xl/_rels/workbook.xml.rels','<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'+''.join(f'<Relationship Id="s{s}" Type="{rel}/worksheet" Target="worksheets/sheet{s}.xml"/>' for s in range(1,33))+'</Relationships>')
     for s in range(1,33):
      xml=f'<worksheet xmlns="{ns}"><sheetData>'
      xml+=''.join(f'<row r="{r}">'+''.join(f'<c r="{c}{r}" t="inlineStr"><is><t>TOKEN{s:02d}{r:04d}{c}</t></is></c>' for c in 'ABCD')+'</row>' for r in range(1,3001))
      z.writestr(f'xl/worksheets/sheet{s}.xml',xml+'</sheetData></worksheet>')
    media=source/'media';media.mkdir(exist_ok=True)
    def chunk(kind,data):return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data)&0xffffffff)
    rng=random.Random(20260905)
    lines=['# Media benchmark']
    for i in range(64):
     raw=b''.join(b'\0'+rng.randbytes(512*3) for _ in range(512))
     png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',512,512,8,2,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')
     (media/f'image{i:02d}.png').write_bytes(png)
     lines.append(f'DOCXTOKEN{i:02d}\n\n![Image {i:02d}](media/image{i:02d}.png)\n')
    (source/'media.md').write_text('\n\n'.join(lines))
    subprocess.run([pandoc,'media.md','-o','media.docx'],cwd=source,check=True)
    small=source/'small';small.mkdir(exist_ok=True)
    for i in range(200): (small/f'input{i:03d}.csv').write_text(f'Name,Value\nSMALLTOKEN{i:03d},42\n')
    manifest={str(p.relative_to(source)):hashlib.sha256(p.read_bytes()).hexdigest() for p in source.rglob('*') if p.is_file()}
    (root/'source-hashes.json').write_text(json.dumps(manifest,indent=2))
    print(json.dumps({'xlsx_cells':32*3000*4,'docx_images':64,'small_inputs':200,'source_bytes':{n:(source/n).stat().st_size for n in ['large.xlsx','media.docx']}}))


def run_measured(command, error_file):
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=error_file,
                               text=True, start_new_session=True)
    try:
        output, _ = process.communicate(timeout=120)
    except subprocess.TimeoutExpired:
        # SIGTERM gibt der CLI Gelegenheit, auch ihre Werkzeuggruppen und
        # ihren Arbeitsbereich aufzuräumen. Nur eigene Prozesse signalisieren.
        os.killpg(process.pid, signal.SIGTERM)
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.communicate()
        raise RuntimeError("Measurement exceeded its 120-second deadline")
    return subprocess.CompletedProcess(command, process.returncode, stdout=output)


def measure(root, binary, label, repeats, compare):
    # Alle Ziele vorab prüfen, damit eine teilweise vorhandene Messserie
    # weder überschrieben noch unbemerkt mit einem neuen Lauf vermischt wird.
    candidates = [root / f"{label}.json"]
    for case in ["large.xlsx", "media.docx", "small"]:
        for trial in range(repeats):
            candidates += [root / f"{label}-{case}-{trial}", root / f"{label}-{case}-{trial}.time"]
    if any(path.exists() or path.is_symlink() for path in candidates):
        raise FileExistsError("Measurement outputs already exist; choose a new label")
    measurements=[]
    for case in ['large.xlsx','media.docx','small']:
     for trial in range(repeats):
      target=root/f'{label}-{case}-{trial}'; log=root/f'{label}-{case}-{trial}.time'
      with log.open('x') as err:
       run=run_measured(['/usr/bin/time','-l',str(binary),str(root/'inputs'/case),'--output',str(target),'--json'], err)
      if run.returncode: raise RuntimeError((case,run.returncode,run.stdout,log.read_text()))
      data=json.loads(run.stdout)
      text=log.read_text()
      elapsed=float(re.search(r'([\d.]+) real',text).group(1))
      rss=int(re.search(r'(\d+)\s+maximum resident set size',text).group(1))
      files=[target] if target.is_file() else list(target.rglob('*'))
      markdown='\n'.join(p.read_text() for p in files if p.suffix=='.md')
      if case=='large.xlsx':
       tokens=re.findall(r'TOKEN\d{6}[ABCD]',markdown)
       assert len(tokens)==384000 and len(set(tokens))==384000,(len(tokens),len(set(tokens)))
      elif case=='media.docx':
       assert len(re.findall(r'DOCXTOKEN\d\d',markdown))==64
       source_hashes=sorted(hashlib.sha256(p.read_bytes()).hexdigest() for p in (root/'inputs'/'media').glob('*.png'))
       output_hashes=sorted(hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.suffix=='.png')
       assert output_hashes==source_hashes
      else: assert len(re.findall(r'SMALLTOKEN\d{3}',markdown))==200
      output_hashes={str(p.relative_to(target)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files if p.is_file()}
      measurements.append(dict(case=case,trial=trial,seconds=elapsed,maximum_resident_bytes=rss,output_hashes=output_hashes))
      print(case,trial,elapsed,rss,flush=True)
    manifest=json.loads((root/'source-hashes.json').read_text())
    assert all(hashlib.sha256((root/'inputs'/p).read_bytes()).hexdigest()==h for p,h in manifest.items())
    with (root/f'{label}.json').open('x') as result_file:
     json.dump(measurements,result_file,indent=2)
    if compare:
     baseline=json.loads(compare.read_text())
     expected={(row['case'],row['trial']):row['output_hashes'] for row in baseline}
     assert all(row['output_hashes']==expected[(row['case'],row['trial'])] for row in measurements), 'Output hashes differ from comparison run'
     print('All output hashes match the comparison run.')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    create = commands.add_parser("generate", help="Create XLSX, DOCX, and CSV fixtures in a new inputs directory")
    create.add_argument("workspace", type=Path)
    create.add_argument("--pandoc", default=shutil.which("pandoc"))
    run = commands.add_parser("measure", help="Measure wall time/RSS and verify all source tokens and assets")
    run.add_argument("workspace", type=Path)
    run.add_argument("binary", type=Path)
    run.add_argument("label")
    run.add_argument("--repeats", type=int, default=3)
    run.add_argument("--compare", type=Path)
    args = parser.parse_args()
    if args.command == "generate":
        if not args.pandoc:
            parser.error("Pandoc is required to generate the DOCX fixture")
        generate(args.workspace.resolve(), args.pandoc)
    else:
        if not re.fullmatch(r"[A-Za-z0-9_-]+", args.label) or args.repeats < 1:
            parser.error("Use a simple label and a positive repeat count")
        measure(args.workspace.resolve(), args.binary.resolve(), args.label, args.repeats, args.compare)


if __name__ == "__main__":
    main()
