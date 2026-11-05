import os,sys,pathlib,json,subprocess,hashlib,time,signal,ctypes,base64,struct
P=pathlib.Path;root=P(sys.argv[1]).resolve();os.umask(0o077);ctypes.CDLL(None).prctl(36,1,0,0,0)
sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest();cli=root/'cli';binary=root/'runtime/bin/poormans-text';wanted='2f49d54ecd6d9bae4962fcdb7f968ea4eef9c3844701d278a9a507e3e84db07c';assert sha(binary)==wanted
fixtures=root/'fixtures';out=root/'outputs';out.mkdir();home=root/'home';home.mkdir();tmp=root/'tmp';tmp.mkdir();env=dict(os.environ,HOME=str(home),XDG_CONFIG_HOME=str(home/'config'),XDG_CACHE_HOME=str(home/'cache'),XDG_DATA_HOME=str(home/'data'),TMPDIR=str(tmp),PATH='/usr/bin:/bin')
result={'cliSHA256Before':wanted,'cases':[],'failures':[],'environment':{'osRelease':P('/etc/os-release').read_text(),'architecture':os.uname().machine}};records=result['cases'];started=time.monotonic()

def save():(root/'evidence.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n')
def check(record,name,value):
 record.setdefault('checks',{})[name]=bool(value)
 if not value:result['failures'].append({'case':record['case'],'check':name})
def clean_children(record):
 adopted=[];deadline=time.monotonic()+2
 while True:
  while True:
   try:pid,status=os.waitpid(-1,os.WNOHANG)
   except ChildProcessError:break
   if not pid:break
   adopted.append(pid)
  children=P('/proc/self/task/'+str(os.getpid())+'/children').read_text().split()
  if not children or time.monotonic()>deadline:break
  time.sleep(.02)
 record['adoptedExitedChildren']=len(adopted);record['remainingOwnChildren']=[int(p) for p in children];check(record,'noOwnChildren',not children)
 if children:raise RuntimeError('owned children remain; stop before next case')

def run(name,args,expected=0,output=None):
 assert time.monotonic()-started<600
 before=sha(binary);record={'case':name,'expectedExit':expected,'executedCLIHash':before};records.append(record)
 child=subprocess.Popen([os.fsencode(cli)]+[os.fsencode(a) if not isinstance(a,bytes) else a for a in args],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE);fd=os.pidfd_open(child.pid)
 try:
  try:stdout,stderr=child.communicate(timeout=45)
  except subprocess.TimeoutExpired:
   signal.pidfd_send_signal(fd,signal.SIGTERM);stdout,stderr=child.communicate(timeout=5);record['timeout']=True
 finally:os.close(fd)
 record['exit']=child.returncode;record['stderr']=stderr.decode(errors='replace')[:1000];check(record,'expectedExit',child.returncode==expected);check(record,'sameRuntime',sha(binary)==before==wanted)
 try:value=json.loads(stdout)
 except Exception:value=None
 record['json']=value
 if output is not None and expected:check(record,'noOutput',not output.exists())
 clean_children(record);save();return record,value

def convert(name,source,args=None,expected=0):
 destination=out/name;before=sha(source);r,v=run(name,['--json','--report','--source-map']+(args or [])+['-o',str(destination),'--',str(source)],expected,destination);r['sourceSHA256']=before;check(r,'sourceUnchanged',sha(source)==before)
 if expected==0 and v and v.get('ok'):
  text=P(v['markdownFile']).read_text();r['markdown']=text;r['outputs']=[]
  for entry in v.get('outputFiles',[]):
   relative=P(entry['path']);assert not relative.is_absolute() and '..' not in relative.parts
   target=P(v['outputDirectory'])/relative;check(r,'manifest-'+entry['path'],target.stat().st_size==entry['byteCount'] and sha(target)==entry['sha256']);r['outputs'].append(entry)
  for mapping in v.get('sourceMappings',[]):
   m=mapping['output'];data=(P(v['outputDirectory'])/m['file']).read_bytes();start=m['utf8Offset'];length=m['utf8Length'];assert start+length<=len(data);data[:start].decode();data[start:start+length].decode()
 save();return r,v

try:
 manifest=json.loads((root/'runtime-manifest.json').read_text());assert all(sha(root/'runtime'/p)==h for p,h in manifest['files'].items())
 fm=json.loads((root/'fixture-manifest.json').read_text());assert all(sha(fixtures/p)==h for p,h in fm.items())
 r,v=run('version',['--version']);r['version']=subprocess.check_output([str(cli),'--version'],env=env,text=True).strip()
 r,catalog=run('catalog',['--formats','--json']);rows=catalog['formats'];check(r,'all29Rows',len(rows)==29);byformat={i['format']:i for i in rows};result['catalog']=rows
 for index,name in enumerate(['Café.csv','Cafe\u0301.csv','Case.csv','case.csv']):
  r,v=convert('csv-'+str(index),fixtures/name);check(r,'independentCSVValues',all(s in r.get('markdown','') for s in ['Name','Value','Grüße β','42']))
 if byformat['xlsx']['available']:
  r,v=convert('xlsx',fixtures/'cells.xlsx');check(r,'independentXLSXValues',all(s in r.get('markdown','') for s in ['Name','Value','Grüße β','42']))
 for name in ['image.png','single.heic','multi.heic']:
  heic=name.endswith('heic');available=not heic or 'heic' in byformat['image']['extensions'];r,v=convert(name,fixtures/name,['--image-ocr','off'],0 if available else 69)
  if r['exit']==0 and v.get('ok'):
   assets=[P(p) for p in v['assets']];check(r,'originalAssetByteIdentity',any(p.read_bytes()==(fixtures/name).read_bytes() for p in assets))
   if heic:check(r,'allPortableFrames',len([p for p in assets if p.suffix=='.png'])==(2 if name.startswith('multi') else 1))
 for name,index in [('image.png',1),('single.heic',1),('multi.heic',2)]:
  available=name.endswith('png') or 'heic' in byformat['image']['extensions'];r,v=run('preview-'+name,['--json','--preview-frame',str(index),'--',str(fixtures/name)],0 if available else 69)
  if r['exit']==0:
   p=v['preview'];png=base64.b64decode(p['png'],validate=True);check(r,'previewSourceIdentity',p['sourceIdentity']['sha256']==sha(fixtures/name));check(r,'previewPNGHash',hashlib.sha256(png).hexdigest()==p['sha256'] and len(png)==p['byteCount']);check(r,'previewSelection',p['index']==index);check(r,'previewDimensions',struct.unpack('>II',png[16:24])==(p['width'],p['height']) and max(p['width'],p['height'])<=1024)
 pdf=byformat['pdf']['available'];r,v=run('pdf-page2',['--json','--preview-page','2','--',str(fixtures/'pages.pdf')],0 if pdf else 69)
 if r['exit']==0:check(r,'page2Source',v['preview']['index']==2 and v['preview']['count']==2 and v['preview']['sourceIdentity']['sha256']==sha(fixtures/'pages.pdf'))
 convert('missing-docx',fixtures/'picture.docx',expected=69)
 convert('missing-ocr',fixtures/'image.png',['--image-ocr','on'],expected=69)
 invalid=os.fsencode(fixtures)+b'/invalid-\xff.csv';fd=os.open(invalid,os.O_CREAT|os.O_WRONLY|os.O_EXCL,0o600);os.write(fd,b'Key,Value\nInvalid,1\n');os.close(fd)
 r,v=run('invalid-utf8',['--json','-o',str(out/'invalid-utf8'),'--',invalid],64,out/'invalid-utf8')
 folder=fixtures/'bad-entry';folder.mkdir();fd=os.open(os.fsencode(folder)+b'/bad-\xff.csv',os.O_CREAT|os.O_WRONLY|os.O_EXCL,0o600);os.write(fd,b'Key,Value\nX,1\n');os.close(fd)
 r,v=run('invalid-utf8-directory-entry',['--json','-o',str(out/'bad-entry'),'--',str(folder)],74,out/'bad-entry')
 existing=out/'existing';existing.mkdir();sentinel=existing/'sentinel';sentinel.write_bytes(b'OLD BYTES');r,v=run('existing-target',['--json','-o',str(existing),'--',str(fixtures/'Case.csv')],73);check(r,'oldTargetBytes',sentinel.read_bytes()==b'OLD BYTES' and list(existing.iterdir())==[sentinel])
 real=out/'real-parent';real.mkdir();link=out/'parent-link';link.symlink_to(real,target_is_directory=True);r,v=run('symlink-parent',['--json','-o',str(link/'result'),'--',str(fixtures/'Case.csv')],74,real/'result');check(r,'foreignParentEmpty',not list(real.iterdir()))
 result['fixtureHashesUnchanged']=all(sha(fixtures/p)==h for p,h in fm.items());result['cliSHA256After']=sha(binary);result['finished']=True
except BaseException as e:result['error']=repr(e);result['finished']=False
finally:result['seconds']=round(time.monotonic()-started,3);save()
