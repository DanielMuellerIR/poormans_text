import hashlib,json,os,subprocess
from pathlib import Path
sha=lambda p:hashlib.file_digest(Path(p).open('rb'),'sha256').hexdigest()
assert os.getuid()==0
mapping=Path('/proc/self/uid_map').read_text();assert mapping.split()[:2]==['0','1000'],mapping
assert not Path('/host/home').exists() and not Path('/run/dbus').exists() and not Path('/run/user').exists()
probes=[]
for p in ['/host/usr/bin/true','/usr/bin/true','/outside-marker','/inputs/old.deb','/host/usr/PMT-forbidden-marker']:
 try:
  with open(p,'ab') as f:f.write(b'FAIL')
 except OSError as e:probes.append({'path':p,'writeDenied':True,'errno':e.errno})
 else:raise AssertionError('RO guard failed: '+p)
Path('/work/boundary.json').write_text(json.dumps({'uidMap':mapping,'writeProbes':probes,'noHostHomeOrBus':True,'networkInterfaces':Path('/proc/net/dev').read_text()},indent=2)+'\n')
source=Path('/work/source.csv');sourceHash=sha(source);profiles=Path('/work/profiles');profileBytes=None;records=[]
def cli(*args):
 p=subprocess.run(['/usr/bin/poormans-text',*map(str,args)],capture_output=True,text=True,timeout=30);assert p.returncode==0,(args,p.returncode,p.stdout,p.stderr);return json.loads(p.stdout)
for i,deb in enumerate(['/inputs/old.deb','/inputs/new.deb']):
 p=subprocess.run(['dpkg','--install',deb],capture_output=True,text=True,timeout=90);Path(f'/work/dpkg-install-{i}.stdout').write_text(p.stdout);Path(f'/work/dpkg-install-{i}.stderr').write_text(p.stderr);assert p.returncode==0,(deb,p.stdout,p.stderr)
 result=cli('--json','--report','--output',f'/work/result-{i}',source);md=Path(result['markdownFile']).read_text();assert all(s in md for s in ['Äpfel','Birnen','12','7'])
 if i==0:
  cli('--json','--profiles-directory',profiles,'--save-profile','Behalten ü','--frontmatter');profileBytes={p.name:p.read_bytes() for p in profiles.iterdir()}
 assert profileBytes=={p.name:p.read_bytes() for p in profiles.iterdir()};assert sha(source)==sourceHash;assert any(x['name']=='Behalten ü' for x in cli('--json','--profiles-directory',profiles,'--list-profiles')['profiles']);records.append({'version':result['version'],'conversionPassed':True,'profilePreserved':True})
p=subprocess.run(['dpkg','--remove','poormans-text'],capture_output=True,text=True,timeout=90);Path('/work/dpkg-remove.stdout').write_text(p.stdout);Path('/work/dpkg-remove.stderr').write_text(p.stderr);assert p.returncode==0,(p.stdout,p.stderr)
assert not Path('/usr/bin/poormans-text').exists() and not Path('/usr/lib/poormans-text').exists();assert profileBytes=={p.name:p.read_bytes() for p in profiles.iterdir()} and sha(source)==sourceHash
Path('/work/lifecycle.json').write_text(json.dumps({'normalDPKG':True,'noSkippedTriggersOrDependencyBypass':True,'installs':records,'packageRemoved':True,'sourceAndProfilePreserved':True},ensure_ascii=False,indent=2)+'\n');print('private dpkg lifecycle PASS')
