from pathlib import Path
from PIL import Image
import os,json,hashlib,base64,subprocess,io,time,struct
root=Path(os.environ.get('PMT_PREVIEW_TEST_ROOT','/probe'));fixtures=root/'fixtures';results=root/'results';results.mkdir(exist_ok=True)
cli=os.environ.get('PMT_PREVIEW_TEST_CLI','/candidate/poormans-text');environment=dict(os.environ);environment['LD_LIBRARY_PATH']=os.environ.get('PMT_PREVIEW_TEST_LIBS','/candidate:/base-runtime/lib')
receipts=[]
def run(name,option,index,source,ok=True,extra=()):
 before=hashlib.file_digest((fixtures/source).open('rb'),'sha256').hexdigest();started=time.monotonic()
 p=subprocess.run([cli,'--json',option,str(index),*extra,'--',str(fixtures/source)],capture_output=True,env=environment,timeout=40)
 assert p.stdout,(name,p.returncode,p.stderr.decode());v=json.loads(p.stdout);assert (p.returncode==0)==ok,(name,p.returncode,v,p.stderr.decode())
 assert hashlib.file_digest((fixtures/source).open('rb'),'sha256').hexdigest()==before
 record={'case':name,'exit':p.returncode,'seconds':time.monotonic()-started,'sourceUnchanged':True,'stderr':p.stderr.decode()[:2048]}
 if ok:
  assert v['operation']=='source-preview' and isinstance(v['version'],str) and bool(v['version']) and v['ok'] is True
  assert not any(k in v for k in ['outputDirectory','markdownFile','assets'])
  preview=v['preview'];data=base64.b64decode(preview['png'],validate=True);assert base64.b64encode(data).decode()==preview['png']
  assert len(data)==preview['byteCount']<=5*1024**2 and hashlib.sha256(data).hexdigest()==preview['sha256']
  assert preview['sourceIdentity']['sha256']==before and preview['sourceIdentity']['byteCount']==(fixtures/source).stat().st_size
  image=Image.open(io.BytesIO(data));image.load();assert image.size==(preview['width'],preview['height']);assert max(image.size)<=1024
  chunks=[];offset=8
  while offset<len(data):
   length=int.from_bytes(data[offset:offset+4],'big');chunks.append(data[offset+4:offset+8].decode());offset+=12+length
  assert not any(t in chunks for t in ['iCCP','iTXt','tEXt','zTXt','eXIf']),chunks
  (results/(name+'.png')).write_bytes(data);record['preview']={k:x for k,x in preview.items() if k!='png'};record['pngChunks']=chunks
 else:
  expected=64 if name.startswith('reject-output') else 65
  assert p.returncode==expected,(name,p.returncode,v)
  record['response']=v
 receipts.append(record);return (Image.open(io.BytesIO(data)).convert('RGB'),preview) if ok else v
p,pv=run('page2','--preview-page',2,'pages.pdf');assert pv['index']==2 and pv['count']==2 and p.getpixel((2,2))[2]>240
p,pv=run('rotated-page2','--preview-page',2,'rotated.pdf');assert pv['height']>pv['width'] and p.getpixel((2,2))[2]>240
p,pv=run('alpha-metadata','--preview-frame',1,'alpha.png');assert p.getpixel((10,10))==(255,255,255) and p.getpixel((60,10))==(0,220,0)
p,pv=run('oriented','--preview-frame',1,'oriented.jpg');assert p.size==(80,40)
for name in ['frames.tiff','frames.gif']:
 p,pv=run(name,'--preview-frame',2,name);assert pv['index']==2 and pv['count']==2 and p.getpixel((10,10))[2]>240
p,pv=run('downscaled','--preview-frame',1,'large.png');assert max(p.size)==1024
for name,index in [('single.heic',1),('rotated.heic',1),('multi.heic',2)]:
 p,pv=run(name,'--preview-frame',index,name);assert pv['count']==(2 if name=='multi.heic' else 1)
for option,index,name in [('--preview-page',3,'pages.pdf'),('--preview-frame',3,'frames.tiff'),('--preview-frame',1,'broken.png'),('--preview-frame',1,'over-source.png'),('--preview-frame',1,'over-pixels.png'),('--preview-frame',1,'oversize.heic'),('--preview-frame',1,'broken.heic')]:run('reject-'+name+'-'+str(index),option,index,name,False)
run('reject-output','--preview-frame',1,'alpha.png',False,['--output',str(results/'must-not-exist')]);assert not (results/'must-not-exist').exists()
(results/'cli-receipts.json').write_text(json.dumps(receipts,ensure_ascii=False,indent=2)+'\n');print(json.dumps({'cases':len(receipts),'passed':len(receipts)}))
