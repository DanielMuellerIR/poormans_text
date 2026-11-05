from pathlib import Path
from PIL import Image
import subprocess,os,json,hashlib,argparse
parser=argparse.ArgumentParser();parser.add_argument("--root",required=True);parser.add_argument("--cli",required=True);parser.add_argument("--pandoc",required=True);parser.add_argument("--heic-single");parser.add_argument("--heic-multi");args=parser.parse_args()
r=Path(args.root);r.mkdir(exist_ok=False);f=r/'fixtures';f.mkdir(exist_ok=True);o=r/'probe-output';o.mkdir(exist_ok=True)
valid=f/'Valid.rtfd';valid.mkdir(exist_ok=True);Image.new('RGB',(16,12),'red').save(valid/'local picture.png')
rtf=br'''{\rtf1\ansi\ansicpg1252\deff0{\fonttbl{\f0 Arial;}}\f0\fs24 Before ALPHA Gr\'fc\'dfe aus M\'fcnchen \u937?\par \pard\ls1\ilvl0{\listtext\u8226  }First item\par \ls1\ilvl0{\listtext\u8226  }Second item\par \pard {\NeXTGraphic local picture.png \width16 \height12} After OMEGA\par}'''
(valid/'TXT.rtf').write_bytes(rtf)
cases={'valid':valid}
literal=f/'Literal.rtfd';literal.mkdir();(literal/'TXT.rtf').write_bytes(br'{\rtf1\ansi \u8226? First\line Continuation\par \u8226? Second\par End}')
cases['literal']=literal
encoded=f/'EncodedName.rtfd';encoded.mkdir();(encoded/'TXT.rtf').write_bytes(br"{\rtf1\ansi\ansicpg1252 Name {\NeXTGraphic gr\'fcne.png \width16 \height12}}")
(encoded/'grüne.png').write_bytes((valid/'local picture.png').read_bytes());cases['encoded-name']=encoded
for name,ref in [('remote','https://example.invalid/a.png'),('escape','../outside.png'),('missing','missing.png'),('absolute','/tmp/outside.png')]:
 pkg=f/(name+'.rtfd');pkg.mkdir(exist_ok=True);(pkg/'TXT.rtf').write_bytes(b'{\\rtf1\\ansi Before {\\NeXTGraphic '+ref.encode()+b' \\width1 \\height1} After}');cases[name]=pkg
for name in ['corrupt','symlink','fifo','unused']:
 pkg=f/(name+'.rtfd');pkg.mkdir(exist_ok=True);(pkg/'TXT.rtf').write_bytes(b'{\\rtf1\\ansi Before {\\NeXTGraphic image.png \\width1 \\height1} After}')
 if name=='corrupt':(pkg/'image.png').write_bytes(b'\x89PNG\r\n\x1a\nBAD')
 if name=='symlink':(pkg/'image.png').symlink_to(valid/'local picture.png')
 if name=='fifo':os.mkfifo(pkg/'image.png')
 if name=='unused':
  (pkg/'TXT.rtf').write_bytes(b'{\\rtf1\\ansi Text without referenced attachment}')
  (pkg/'extra.pdf').write_bytes(b'%PDF-1.4 unused fixture')
 cases[name]=pkg
# Echte Encoderfixtures; erwartete Texte und Originalbytes stammen nicht aus PMT.
static_cases = {}
for extension, format_name in [('jpg', 'JPEG'), ('JPEG', 'JPEG'), ('tiff', 'TIFF'), ('tif', 'TIFF'), ('gif', 'GIF'), ('bmp', 'BMP'), ('webp', 'WEBP')]:
 name = 'static-' + extension;pkg=f/(name+'.rtfd');pkg.mkdir();filename='local picture.'+extension
 Image.new('RGB',(16,12),'red').save(pkg/filename,format=format_name)
 (pkg/'TXT.rtf').write_bytes(b'{\\rtf1\\ansi BEFORE {\\NeXTGraphic '+filename.encode()+b' \\width16 \\height12} AFTER}')
 cases[name]=pkg;static_cases[name]=filename
for extension, format_name in [('gif','GIF'),('tiff','TIFF'),('png','PNG'),('webp','WEBP')]:
 name='multi-'+extension;pkg=f/(name+'.rtfd');pkg.mkdir();filename='image.'+extension
 first=Image.new('RGB',(16,12),'red');second=Image.new('RGB',(16,12),'blue')
 first.save(pkg/filename,format=format_name,save_all=True,append_images=[second],duration=100,loop=0)
 (pkg/'TXT.rtf').write_bytes(b'{\\rtf1 BEFORE {\\NeXTGraphic '+filename.encode()+b'} AFTER}');cases[name]=pkg
mismatch=f/'Mismatch.rtfd';mismatch.mkdir();(mismatch/'image.jpg').write_bytes((valid/'local picture.png').read_bytes());(mismatch/'TXT.rtf').write_bytes(br'{\rtf1 BEFORE {\NeXTGraphic image.jpg} AFTER}');cases['mismatch']=mismatch
for name, source in [('static-heic',args.heic_single),('multi-heic',args.heic_multi)]:
 if source:
  pkg=f/(name+'.rtfd');pkg.mkdir();(pkg/'original.heic').write_bytes(Path(source).read_bytes());(pkg/'TXT.rtf').write_bytes(br'{\rtf1 BEFORE {\NeXTGraphic original.heic} AFTER}');cases[name]=pkg
  if name=='static-heic':static_cases[name]='original.heic'
successes={'valid','unused','literal','encoded-name'}|set(static_cases)
sourcehash={str(p.relative_to(f)):hashlib.sha256(p.read_bytes()).hexdigest() for p in f.rglob('*') if p.is_file() and not p.is_symlink()}
env=dict(os.environ,LD_LIBRARY_PATH=str(r/'runtime/lib'));cli=Path(args.cli).resolve();pandoc=str(Path(args.pandoc).resolve());env['LD_LIBRARY_PATH']=str(cli.parent.parent/'lib');res={}
catalog=subprocess.run([str(cli),'--json','--formats'],env=env,capture_output=True,text=True,timeout=15);assert catalog.returncode==0,catalog.stderr
heic_available='heic' in next(row for row in json.loads(catalog.stdout)['formats'] if row['format']=='image')['extensions']
if not heic_available:successes.discard('static-heic')
for name,pkg in cases.items():
 p=subprocess.run([str(cli),'--json','--pandoc',pandoc,'-o',str(o/name),str(pkg)],env=env,capture_output=True,text=True,timeout=15)
 try:j=json.loads(p.stdout)
 except:j={}
 md='';assets=[]
 if (o/name).exists():
  for path in (o/name).glob('*.md'):md=path.read_text()
  assets=[str(x.relative_to(o/name)) for x in (o/name/'images').glob('*')]
 res[name]=dict(exit=p.returncode,result=j,stderr=p.stderr,markdown=md,assets=assets)
 assert (name in successes)==(p.returncode==0),(name,p.stdout,p.stderr)
 if name=='valid':
  for marker in ['Before ALPHA','Grüße aus München Ω','First item','Second item','After OMEGA']:assert marker in md,(marker,md)
  assert len(assets)==1,md
  assert (o/name/assets[0]).read_bytes()==(valid/'local picture.png').read_bytes()
  assert not any(d['code']=='richText.attachmentNotRepresented' for d in j.get('diagnostics',[])),j
 if name not in successes:assert not (o/name).exists(),(name,p.stdout)
 if name in ['static-heic','multi-heic'] and not heic_available:assert p.returncode==69,(name,p.stdout)
 if name in static_cases and name in successes:
  assert len(assets)==1,(name,assets)
  original=pkg/static_cases[name];asset=o/name/assets[0]
  assert asset.read_bytes()==original.read_bytes(),name
  assert asset.suffix==original.suffix.lower(),(name,asset)
  image_position=md.index('![');assert md.index('BEFORE')<image_position<md.index('AFTER'),(name,md)
  viewer_warning=any(d['code']=='rtfd.viewerCompatibility' for d in j.get('diagnostics',[]))
  assert viewer_warning==(original.suffix.lower() in ['.tif','.tiff','.heic']),(name,j)
  res[name]['sourceAssetSHA256']=hashlib.sha256(original.read_bytes()).hexdigest();res[name]['outputAssetSHA256']=hashlib.sha256(asset.read_bytes()).hexdigest()
 if name=='literal':assert '- First  \n  Continuation\n- Second' in md,md
 if name=='encoded-name':assert len(assets)==1 and (o/name/assets[0]).read_bytes()==(valid/'local picture.png').read_bytes()
 if name=='unused':assert any(d['code']=='richText.attachmentNotRepresented' for d in j.get('diagnostics',[])),j
assert sourcehash=={str(p.relative_to(f)):hashlib.sha256(p.read_bytes()).hexdigest() for p in f.rglob('*') if p.is_file() and not p.is_symlink()}
(r/'probe-results.json').write_text(json.dumps(res,indent=2,ensure_ascii=False));print(json.dumps({k:{'exit':v['exit'],'markdown':v['markdown'],'assets':v['assets'],'error':v['result'].get('error')} for k,v in res.items()},indent=2,ensure_ascii=False))
