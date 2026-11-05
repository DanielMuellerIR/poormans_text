from pathlib import Path
import os,json,subprocess,hashlib,time,base64,io
from collections import Counter
from PIL import Image
root=Path(__file__).resolve().parent;runtime=root/'extracted/usr/lib/poormans-text';cli=runtime/'bin/poormans-text';f=root/'fixtures';sample=f/'fixtures/sample.pdf';out=root/'outputs';out.mkdir()
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
env=dict(os.environ,LD_LIBRARY_PATH=str(runtime/'lib'));res={};hashes={str(p.relative_to(f)):sha(p) for p in f.rglob('*.pdf')}
cases=[('dates',f/'dates.pdf',['--frontmatter']),('structured-off',sample,['--ocr-method','structured']),('digital',sample,[]),('second',sample,['--pdf-pages','2']),('headers',f/'margins.pdf',['--pdf-remove-headers-footers']),('hyphen',f/'hyphen.pdf',['--pdf-dehyphenate']),('legacy',sample,['--pdf-layout','legacy']),('broken',f/'broken.pdf',[]),('encrypted',f/'encrypted.pdf',[]),('out-of-range',sample,['--pdf-pages','3'])]
for name,source,flags in cases:
 p=subprocess.run([str(cli),'--json','--report','--source-map','--pdf-ocr','off','--output',str(out/name),*flags,str(source)],env=env,capture_output=True,text=True,timeout=25);v=json.loads(p.stdout);expected=65 if name in ['broken','encrypted','out-of-range'] else 0;assert p.returncode==expected,(name,p.returncode,v,p.stderr)
 md=Path(v['markdownFile']).read_text() if p.returncode==0 else '';res[name]={'exit':p.returncode,'response':v,'markdown':md,'stderr':p.stderr,'sourceSHA256':sha(source)}
 if expected:assert not (out/name).exists();continue
 assert not any(d['code']=='pdf.ocrApplied' for d in v.get('diagnostics',[])),v
 if name=='dates':assert v['metadata']['created']=='1969-01-02T03:04:05Z' and v['metadata']['modified']=='2020-01-02T03:04:05Z' and 'created: 1969-01-02T03:04:05Z' in md
 if name=='digital':
  for marker in ['ALPHA left column','BETA right','GAMMA next line','DELTA page two','NOTE annotation sentinel','https://example.invalid/pmt-never-fetch','Fixture author']:assert marker in md,(marker,md)
  assert len(v['assets'])==1;image=Image.open(v['assets'][0]);image.load();assert image.size==(2,2);assert list(image.convert('RGB').getdata())==[(255,0,0),(0,255,0),(0,0,255),(255,255,0)]
  body=md.split('## Page 1\n\n',1)[1].split('\n\n![PDF image]',1)[0];assert Counter(body.split())==Counter('ALPHA left column BETA right GAMMA next line'.split())
  res[name]['assetSHA256']=sha(v['assets'][0]);res[name]['independentAssetPixelsMatch']=True
 if name=='second':assert 'DELTA page two' in md and 'ALPHA' not in md and not v['assets']
 if name=='headers':assert md.count('REPEATED HEADER')==1 and 'REPEATED FOOTER' not in md and 'BODY ALPHA' in md and 'BODY BETA' in md
 if name=='hyphen':assert 'fortsetzungsbeispiel' in md and 'fortsetzungs-' not in md
 if name=='legacy':assert md.index('ALPHA left column')<md.index('GAMMA next line')<md.index('BETA right')
 assert v['sourceIdentity']['sha256']==sha(source)
 for item in v['outputFiles']:
  file=out/name/item['path'];assert file.stat().st_size==item['byteCount'] and sha(file)==item['sha256']
 for mapping in v.get('sourceMappings',[]):
  data=(out/name/mapping['output']['file']).read_bytes();start=mapping['output']['utf8Offset'];end=start+mapping['output']['utf8Length'];data[:start].decode();data[start:end].decode()
p=subprocess.run([str(cli),'--json','--pdf-ocr','always','--output',str(out/'missing-ocr'),str(sample)],env=env,capture_output=True,text=True,timeout=25);v=json.loads(p.stdout);assert p.returncode==69 and not (out/'missing-ocr').exists() and 'Tesseract' in v['error'];res['missing-ocr']={'exit':p.returncode,'response':v,'sourceSHA256':sha(sample)}
p=subprocess.run([str(cli),'--json','--preview-page','2',str(sample)],env=env,capture_output=True,text=True,timeout=25);assert p.returncode==0,(p.stdout,p.stderr);v=json.loads(p.stdout);pv=v['preview'];data=base64.b64decode(pv['png'],validate=True);assert base64.b64encode(data).decode()==pv['png'];assert len(data)==pv['byteCount']<=5*1024**2 and hashlib.sha256(data).hexdigest()==pv['sha256'];assert pv['index']==2 and pv['count']==2 and pv['sourceIdentity']['sha256']==sha(sample)
im=Image.open(io.BytesIO(data));im.load();assert im.size==(pv['width'],pv['height'])==(768,1024);assert im.convert('RGB').getpixel((0,0))==(255,255,255);assert any(px!=(255,255,255) for px in im.convert('RGB').getdata());(root/'preview-page2.png').write_bytes(data)
res['preview-page2']={'exit':p.returncode,'preview':{k:x for k,x in pv.items() if k!='png'},'independentlyDecoded':True}
assert hashes=={str(p.relative_to(f)):sha(p) for p in f.rglob('*.pdf')}
(root/'pdf-results.json').write_text(json.dumps({'host':os.uname().nodename,'native':True,'runtimeCLI_SHA256':sha(cli),'cases':res,'sourceHashes':hashes,'allSourcesUnchanged':True,'standardOCRQualityClaimed':False},ensure_ascii=False,indent=2)+'\n');print(json.dumps({'nativePDFCases':len(res),'passed':len(res)}))
