#!/usr/bin/env python3
"""Expliziter Offline-Probenlauf; kein Produktaufruf und keine Modellinferenz."""
import argparse, hashlib, json, pathlib, shutil, subprocess
p=argparse.ArgumentParser()
p.add_argument('--repo',required=True,type=pathlib.Path)
p.add_argument('--work',required=True,type=pathlib.Path,help='Neuer, noch nicht vorhandener Ordner unter /tmp')
p.add_argument('--image',default='pmt-linux-builder')
p.add_argument('--prepare-only',action='store_true')
a=p.parse_args();repo=a.repo.resolve(strict=True);work=a.work.absolute()
if work.parent.resolve(strict=True)!=work.parent or not str(work).startswith('/tmp/'):
 p.error('--work muss unter /tmp liegen; Eltern dürfen keine Symlinks enthalten')
work.mkdir(mode=0o700)
here=pathlib.Path(__file__).resolve().parent
manifest=json.loads((here/'inputs.json').read_text())
for item in manifest['coreSources']+manifest['fixtures']:
 path=repo/item['path'];data=path.read_bytes()
 if len(data)!=item['bytes'] or hashlib.sha256(data).hexdigest()!=item['sha256']:
  raise SystemExit('Quellstand abweichend: '+item['path'])
source=work/'source';source.mkdir();(source/'Sources').mkdir();fixtures=work/'fixtures';fixtures.mkdir()
for name in ['PoorMansTextCore','CPMTLinux','CZlib']:
 shutil.copytree(repo/'Sources'/name,source/'Sources'/name)
probe=source/'Sources/ProjectionProbe';probe.mkdir()
for name in ['main.swift']:shutil.copyfile(here/name,probe/name)
shutil.copyfile(here/'Package.swift',source/'Package.swift')
for item in manifest['fixtures']:shutil.copyfile(repo/item['path'],fixtures/pathlib.Path(item['path']).name)
# Python indiziert Unicode-Codepoints; Swift vergleicht die Bytes der identischen Fragmente.
text='é🙂e\u0301';spans=[[0,1],[1,2],[2,4]]
control={'text':text,'pythonCodepointCount':len(text),'spans':spans,
 'fragments':[text[s:e] for s,e in spans],'utf8Hex':text.encode().hex()}
(fixtures/'unicode-control.json').write_text(json.dumps(control,ensure_ascii=False)+'\n')
cache=work/'cache';cache.mkdir()
if a.prepare_only:
 print(json.dumps({'prepared':str(work),'modelExecution':False}));raise SystemExit(0)
deps=repo/'.build/linux/docker/checkouts'
for name in ['swift-crypto','swift-asn1']:
 if not (deps/name).is_dir():raise SystemExit('Erforderlicher vorhandener Offline-Checkout fehlt: '+name)
common=['docker','run','--rm','--pull','never','--network','none','--user',f'{__import__("os").getuid()}:{__import__("os").getgid()}']
build=common+['-e','HOME=/tmp','-e','SWIFTCI_USE_LOCAL_DEPS=1','--mount',f'type=bind,source={source},target=/source',
 '--mount',f'type=bind,source={deps},target=/dependencies,readonly','--mount',f'type=bind,source={cache},target=/cache',
 '-w','/source',a.image,'swift','build','--scratch-path','/cache','--jobs','4','--product','p11-projection']
with (work/'build.log').open('wb') as out:subprocess.run(build,stdout=out,stderr=subprocess.STDOUT,check=True,timeout=600)
run=common+['--read-only','--mount',f'type=bind,source={cache},target=/cache,readonly','--mount',f'type=bind,source={fixtures},target=/fixtures,readonly',
 a.image,'/cache/x86_64-unknown-linux-gnu/debug/p11-projection','/fixtures']
with (work/'results.json').open('wb') as out,(work/'run.stderr').open('wb') as err:
 subprocess.run(run,stdout=out,stderr=err,check=True,timeout=60)
print(json.dumps({'result':str(work/'results.json'),'allPassed':json.loads((work/'results.json').read_text())['allPassed']}))
