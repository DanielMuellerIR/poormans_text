import pathlib,subprocess,json,hashlib,time,sys
r=pathlib.Path('/probe');mode=sys.argv[1];cases=[]
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def run(label,source,args,expected):
 inp=r/'fixtures'/source;before=digest(inp);out=r/'results'/(mode+'-'+label+'-'+str(time.time_ns()));assert not out.exists()
 start=time.monotonic();command=['/candidate/cli','--json','--source-map',*args,'--output',str(out),'--',str(inp)];observed=False
 if mode=='timeout':
  child=subprocess.Popen(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
  while child.poll() is None and time.monotonic()-start<25:
   parents={};sleepers=[]
   for entry in pathlib.Path('/proc').iterdir():
    if not entry.name.isdigit():continue
    try:
     pid=int(entry.name);status=(entry/'status').read_text();parents[pid]=int(next(line for line in status.splitlines() if line.startswith('PPid:')).split()[1])
     if (entry/'cmdline').read_bytes().split(b'\0')[:2]==[b'/bin/sleep',b'5']:sleepers.append(pid)
    except (OSError,ValueError,StopIteration):pass
   for pid in sleepers:
    seen=set()
    while pid in parents and pid not in seen:
     if pid==child.pid:observed=True;break
     seen.add(pid);pid=parents[pid]
   time.sleep(.01)
  if child.poll() is None:child.kill()
  stdout,stderr=child.communicate(timeout=3);p=subprocess.CompletedProcess(command,child.returncode,stdout,stderr)
 else:p=subprocess.run(command,capture_output=True,timeout=25)
 elapsed=time.monotonic()-start
 assert p.stdout,(label,p.returncode,p.stderr.decode());v=json.loads(p.stdout)
 assert p.returncode==expected,(mode,label,p.returncode,v,p.stderr.decode())
 assert digest(inp)==before
 if expected:
  assert v['ok'] is False and not out.exists(),(label,v)
  if mode=='iofault':assert 'IOFaultMarker' in json.dumps(v),v
  if mode=='timeout':assert observed,('controlled recognition sleep not observed',v)
 else:
  assert v['ok'] is True and out.is_dir();assert pathlib.Path(v['markdownFile']).is_file()
  if source.endswith('.png'):
   assets=[pathlib.Path(a) for a in v['assets'] if a.endswith('.png')];assert any(digest(a)==before for a in assets)
  if mode=='real':assert 'image.ocrApplied' not in json.dumps(v),v
 cases.append({'case':label,'source':source,'sourceSHA256':before,'sourceUnchanged':True,'exit':p.returncode,'seconds':elapsed,'published':out.exists(),'controlledRecognitionSleepObserved':observed,'response':v,'stderr':p.stderr.decode()})
if mode=='real':run('blank','blank.png',['--image-ocr','on'],0)
else:
 expected={'nonexec':69,'nolangs':69,'iofault':74,'timeout':124}[mode]
 extra=['--timeout','0.5'] if mode=='timeout' else []
 run('png','ocr.png',['--image-ocr','on',*extra],expected)
 run('pdf','sample.pdf',['--pdf-ocr','always',*extra],expected)
 if mode=='nonexec':
  run('png-off','ocr.png',['--image-ocr','off'],0)
  run('pdf-off','sample.pdf',['--pdf-ocr','off'],0)
(r/'results'/(mode+'.json')).write_text(json.dumps(cases,indent=2)+'\n');print(json.dumps({'controlledMode':mode,'passed':len(cases)}))
