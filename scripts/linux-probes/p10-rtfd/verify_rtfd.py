from pathlib import Path
from PIL import Image
import subprocess,os,json,hashlib,argparse
parser=argparse.ArgumentParser();parser.add_argument("--root",required=True);parser.add_argument("--cli",required=True);parser.add_argument("--pandoc",required=True);args=parser.parse_args()
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
sourcehash={str(p.relative_to(f)):hashlib.sha256(p.read_bytes()).hexdigest() for p in f.rglob('*') if p.is_file() and not p.is_symlink()}
env=dict(os.environ,LD_LIBRARY_PATH=str(r/'runtime/lib'));cli=Path(args.cli).resolve();pandoc=str(Path(args.pandoc).resolve());env['LD_LIBRARY_PATH']=str(cli.parent.parent/'lib');res={}
for name,pkg in cases.items():
 p=subprocess.run([str(cli),'--json','--pandoc',pandoc,'-o',str(o/name),str(pkg)],env=env,capture_output=True,text=True,timeout=15)
 try:j=json.loads(p.stdout)
 except:j={}
 md='';assets=[]
 if (o/name).exists():
  for path in (o/name).glob('*.md'):md=path.read_text()
  assets=[str(x.relative_to(o/name)) for x in (o/name/'images').glob('*')]
 res[name]=dict(exit=p.returncode,result=j,stderr=p.stderr,markdown=md,assets=assets)
 assert (name in ['valid','unused','literal','encoded-name'])==(p.returncode==0),(name,p.stdout,p.stderr)
 if name=='valid':
  for marker in ['Before ALPHA','Grüße aus München Ω','First item','Second item','After OMEGA']:assert marker in md,(marker,md)
  assert len(assets)==1,md
  assert (o/name/assets[0]).read_bytes()==(valid/'local picture.png').read_bytes()
  assert not any(d['code']=='richText.attachmentNotRepresented' for d in j.get('diagnostics',[])),j
 if name=='literal':assert '- First  \n  Continuation\n- Second' in md,md
 if name=='encoded-name':assert len(assets)==1 and (o/name/assets[0]).read_bytes()==(valid/'local picture.png').read_bytes()
 if name=='unused':assert any(d['code']=='richText.attachmentNotRepresented' for d in j.get('diagnostics',[])),j
assert sourcehash=={str(p.relative_to(f)):hashlib.sha256(p.read_bytes()).hexdigest() for p in f.rglob('*') if p.is_file() and not p.is_symlink()}
(r/'probe-results.json').write_text(json.dumps(res,indent=2,ensure_ascii=False));print(json.dumps({k:{'exit':v['exit'],'markdown':v['markdown'],'assets':v['assets'],'error':v['result'].get('error')} for k,v in res.items()},indent=2,ensure_ascii=False))
