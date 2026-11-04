#!/usr/bin/env python3
"""Erzeugt nur einen isolierten Probe-Baum; Quelle wird ausschließlich gelesen."""
from pathlib import Path
import argparse,shutil,json,subprocess,hashlib
parser=argparse.ArgumentParser();parser.add_argument('source',type=Path);parser.add_argument('output',type=Path);args=parser.parse_args()
r=Path(__file__).resolve().parent
if args.output.exists():raise SystemExit('output must not exist')
for name,digest in json.loads((r/'patch-source-hashes.json').read_text()).items():
 source=args.source/'Sources/PoorMansTextCore'/name
 if digest is None:
  if source.exists():raise SystemExit('probe-only file already exists: '+name)
 elif not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest()!=digest:
  raise SystemExit('source differs from tested patch baseline: '+name)
core=args.output/'Sources/PoorMansTextCore';shutil.copytree(args.source/'Sources/PoorMansTextCore',core)
for name in json.loads((r/'excluded.json').read_text()):(core/name).unlink()
subprocess.run(['patch','-p1','--batch','--fuzz=0','-i',str(r/'core.patch')],cwd=args.output,check=True)
for src,dst in [('Package.swift','Package.swift'),('Package.resolved','Package.resolved'),('Dockerfile','Dockerfile'),('main.swift','Sources/Probe/main.swift'),('module.modulemap','Sources/zlib/module.modulemap'),('fixtures.py','fixtures.py'),('run-runtime.sh','run-runtime.sh')]:
 target=args.output/dst;target.parent.mkdir(exist_ok=True,parents=True);shutil.copy2(r/src,target)
(args.output/'fixtures').mkdir();shutil.copy2(args.source/'Tests/PoorMansTextCoreTests/Fixtures/WordProcessing/fixture.png',args.output/'fixtures/fixture.png')
subprocess.run(['python3',str(args.output/'fixtures.py')],check=True)
