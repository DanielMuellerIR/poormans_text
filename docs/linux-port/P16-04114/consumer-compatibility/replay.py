import pathlib,hashlib,json,subprocess,os,time
P=pathlib.Path;root=P('/probe/work');assert os.getuid()==1000
for name in ['home','tmp','config','cache','data','runtime']:(root/name).mkdir(mode=0o700)
env={'PATH':'/usr/bin:/bin','LANG':'C.UTF-8','HOME':str(root/'home'),'TMPDIR':str(root/'tmp'),'XDG_CONFIG_HOME':str(root/'config'),'XDG_CACHE_HOME':str(root/'cache'),'XDG_DATA_HOME':str(root/'data'),'XDG_RUNTIME_DIR':str(root/'runtime')}
h=lambda p:hashlib.sha256(P(p).read_bytes()).hexdigest()
consumer='ebb3feacdbab5b4ddf221b54b092697eb142d68f18cc6e84d03be29a5df2f061';producer='8abc9197eeced8df043d788e349acb553bd86dd81546a6fda1faf15a93bac0cb'
assert h('/probe/check_cli')==consumer and h('/producer/.build/linux-runtime/bin/poormans-text')==producer
start=time.monotonic();p=subprocess.run(['/probe/check_cli','/producer/poormans-text'],env=env,capture_output=True,text=True,timeout=45)
assert p.returncode==0,(p.returncode,p.stdout,p.stderr)
assert 'catalog 0.41.14: 29 formats' in p.stdout
assert 'PASS table.csv: 1 files, 1 documents, entry table.md' in p.stdout
assert 'PASS mail.mbox: 3 files, 2 documents, entry index.md' in p.stdout
assert not list((root/'tmp').iterdir())
assert h('/probe/check_cli')==consumer and h('/producer/.build/linux-runtime/bin/poormans-text')==producer
r={'exit':p.returncode,'seconds':round(time.monotonic()-start,3),'stdout':p.stdout,'stderr':p.stderr,'remainingTempEntries':[],'artifacts':{'consumer':consumer,'producerCLI':producer,'producerGuard':h('/producer/.build/linux-runtime/bin/poormans-text-process-guard'),'rootLauncher':h('/producer/poormans-text')},'unprivilegedUID':1000,'scope':'Unchanged historical real consumer -> current0.41.14 producer; CSV/MBOX only; no current GUI/commit binding, collision or image-attachment test','sourceCommitBinding':'Artifact hashes only'}
P('/probe/delivery/replay.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r,indent=2))
