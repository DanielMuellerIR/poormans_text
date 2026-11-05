from pathlib import Path
from PIL import Image
import os,json,subprocess,hashlib,ctypes,time,signal
r=Path(__file__).parent;root=r/'controls-2';root.mkdir();source=root/'Large.rtfd';source.mkdir();Image.new('RGB',(6000,6000),'red').save(source/'image.jpg');(source/'TXT.rtf').write_bytes(br'{\rtf1 BEFORE {\NeXTGraphic image.jpg} AFTER}')
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();hashes={p.name:sha(p) for p in source.iterdir()};env=dict(os.environ,LD_LIBRARY_PATH=str(r/'runtime/lib'));cli=r/'runtime/bin/poormans-text';pandoc=os.environ['PMT_TEST_PANDOC'];ctypes.CDLL(None).prctl(36,1,0,0,0);results=[]
def descendants(pid):
 result=[]
 try:children=Path('/proc/'+str(pid)+'/task/'+str(pid)+'/children').read_text().split()
 except OSError:return result
 for child in children:
  result.append(int(child));result+=descendants(int(child))
 return result
for name,extra,expected in [('timeout',['--timeout','0.05'],124),('cancel',[],130)]:
 out=root/(name+'-output');p=subprocess.Popen([str(cli),'--json','--pandoc',pandoc,*extra,'-o',str(out),'--',str(source)],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE);fd=os.pidfd_open(p.pid);observed=False
 try:
  if name=='cancel':
   deadline=time.monotonic()+5
   while time.monotonic()<deadline and p.poll() is None:
    for child in descendants(p.pid):
     try:args=Path('/proc/'+str(child)+'/cmdline').read_bytes()
     except OSError:continue
     if b'inspect' in args.split(b'\0') and b'python3' in args.split(b'\0')[0]:observed=True;break
    if observed:break
    time.sleep(.002)
   assert observed,'real raster worker was not observed'
   signal.pidfd_send_signal(fd,signal.SIGTERM)
  stdout,stderr=p.communicate(timeout=15)
 finally:
  if p.poll() is None:signal.pidfd_send_signal(fd,signal.SIGKILL);p.wait()
  os.close(fd)
 deadline=time.monotonic()+2
 while True:
  try:pid,status=os.waitpid(-1,os.WNOHANG)
  except ChildProcessError:break
  if pid==0:
   if time.monotonic()>deadline:break
   time.sleep(.01)
 children=Path('/proc/self/task/'+str(os.getpid())+'/children').read_text().split();value=json.loads(stdout);assert p.returncode==expected and not value.get('ok') and not out.exists() and not children,(name,p.returncode,value,children)
 results.append({'case':name,'exit':p.returncode,'noOutput':not out.exists(),'response':value,'rasterWorkerObservedBeforeCancel':observed if name=='cancel' else None,'remainingOwnChildren':children})
assert hashes=={p.name:sha(p) for p in source.iterdir()}
(r/'controls.json').write_text(json.dumps({'cases':results,'sourceHashes':hashes,'sourceUnchanged':True},indent=2)+'\n');print(json.dumps(results))
