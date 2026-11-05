# Reproduktionsrezept nach Abnahme; nicht erneut ausgeführt.
import json,hashlib,urllib.request,pathlib,subprocess,time
root=pathlib.Path('/opt/p11');root.mkdir();wheels=root/'wheels';wheels.mkdir();cap=750*1024**2
used=lambda:sum(p.stat().st_size for p in root.rglob('*') if p.is_file())
for item in json.loads(pathlib.Path('/setup/assets.json').read_text()):
 path=root/item['path'];path.parent.mkdir(parents=True,exist_ok=True);digest=hashlib.sha256()
 with urllib.request.urlopen(item['url'],timeout=60) as response,path.open('wb') as out:
  while chunk:=response.read(1024*1024):
   if used()+len(chunk)>cap:raise RuntimeError('750MiB setup cap')
   out.write(chunk);digest.update(chunk)
 assert digest.hexdigest()==item['sha256'] and path.stat().st_size==item['size']
p=subprocess.Popen(['/opt/probe/bin/pip','download','--require-hashes','--only-binary=:all:','--dest',str(wheels),'-r','/setup/requirements-resolved.txt'])
while p.poll() is None:
 if used()>cap:p.kill();raise RuntimeError('750MiB setup cap')
 time.sleep(.1)
if p.returncode or used()>cap:raise RuntimeError('bounded wheel setup failed')
local=pathlib.Path('/setup/requirements-resolved.txt').read_text()
for name,version in [('torch','2.8.0+cpu'),('torchvision','0.23.0+cpu')]:
 local='\n'.join((name+'=='+version+' --hash='+line.split(' --hash=')[1]) if line.startswith(name+' @ ') else line for line in local.splitlines())
(root/'requirements-local.txt').write_text(local+'\n')
subprocess.run(['/opt/probe/bin/pip','install','--no-index','--find-links',str(wheels),'--require-hashes','-r',str(root/'requirements-local.txt')],check=True)
