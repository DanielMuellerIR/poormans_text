from pathlib import Path
import os,subprocess,json,hashlib,time,zipfile,shutil
root=Path(__file__).resolve().parent
assert str(root).startswith('/tmp/pmt-mint-04113.') and os.getuid()==1000
(root/'tmp').mkdir(mode=0o700)
os.environ['TMPDIR']=str(root/'tmp')
def sha(p):
 with Path(p).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
pkg=root/'.build/linux-preview-04113/poormans-text_0.41.13~linuxpreview1_amd64.deb';pandoc=root/'pandoc';assert sha(pkg)=='640be59eeacddca4fdb0626a84de2ccba8012cf49eb0e98627af404d28cf80ff';assert sha(pandoc)=='5a953bcbcdc7c36fcb0c263fbb09db8c7b84cfa9ca58e48e321d7edf857a7ee7'
subprocess.run(['dpkg-deb','-x',str(pkg),str(root/'extracted')],check=True,timeout=30)
runtime=root/'extracted/usr/lib/poormans-text';cli=runtime/'bin/poormans-text'
expected={'bin/poormans-text':'26470eaf5d0b474e7f164882683b339ffc63b75d20a3ecdd6856729883f8f460','ui/poormans-text-app':'851d0a76e4214bbd5f599c995a1b78ff40792524a7b1383e6afbda165c43cfa6','bin/poormans-text-process-guard':'cf677f9be88095a27423ceedb9db2b85667f7775d167857cfb52002ff5dda520'}
assert all(sha(runtime/name)==value for name,value in expected.items())
(root/'runtime').symlink_to(runtime)
files={str(p.relative_to(runtime)):sha(p) for p in runtime.rglob('*') if p.is_file()}
(root/'runtime-manifest.json').write_text(json.dumps({'expected':expected,'files':files},indent=2)+'\n')
heic=root/'docs/linux-port/P16-04112/preview/heic-fixtures'
command=['/usr/bin/python3','-I',str(root/'scripts/linux-probes/p10-rtfd/verify_rtfd.py'),'--root',str(root/'rtfd-run'),'--cli',str(cli),'--pandoc',str(pandoc),'--heic-single',str(heic/'single.heic'),'--heic-multi',str(heic/'multi.heic')]
started=time.monotonic();p=subprocess.run(command,capture_output=True,text=True,timeout=180);(root/'rtfd.log').write_text(p.stdout+'\nSTDERR\n'+p.stderr);assert p.returncode==0,(p.returncode,p.stdout[-3000:],p.stderr)
results=json.loads((root/'rtfd-run/probe-results.json').read_text());assert len(results)==25
source=root/'docs/linux-port/P16-04112/mint/fixtures/picture.docx';before=sha(source);output=root/'docx-output';env=dict(os.environ,LD_LIBRARY_PATH=str(runtime/'lib'))
p=subprocess.run([str(cli),'--json','--source-map','--pandoc',str(pandoc),'--output',str(output),str(source)],env=env,capture_output=True,text=True,timeout=30);(root/'docx.log').write_text(p.stdout+'\nSTDERR\n'+p.stderr);assert p.returncode==0,(p.stdout,p.stderr);v=json.loads(p.stdout);md=Path(v['markdownFile']).read_text();assert md.count('DOCXTOKEN')==1 and 'Größe' in md and 'PIXELTOKEN' in md
with zipfile.ZipFile(source) as z:
 originals=[z.read(n) for n in z.namelist() if n.startswith('word/media/') and n.endswith('.png')]
assert len(originals)==1 and len(v['assets'])==1 and Path(v['assets'][0]).read_bytes()==originals[0];assert sha(source)==before
assert v['sourceIdentity']['sha256']==before
sourcehash={str(x.relative_to(root/'rtfd-run/fixtures')):sha(x) for x in (root/'rtfd-run/fixtures').rglob('*') if x.is_file() and not x.is_symlink()}
size=sum(x.stat().st_size for x in root.rglob('*') if x.is_file() and not x.is_symlink());assert size<700*1024**2,size
(root/'evidence.json').write_text(json.dumps({'host':os.uname().nodename,'kernel':os.uname().release,'osRelease':Path('/etc/os-release').read_text(),'native':True,'packageExtractionOnly':True,'packageSHA256':sha(pkg),'pandocSHA256':sha(pandoc),'runtimeHashes':expected,'rtfdCases':len(results),'rtfdStatuses':{k:v['exit'] for k,v in results.items()},'rtfdSourceStabilityAssertedByHarness':True,'rtfdSourceHashes':sourcehash,'docx':{'sourceSHA256':before,'sourceUnchanged':True,'originalPNGAssetSHA256':hashlib.sha256(originals[0]).hexdigest(),'outputAssetSHA256':sha(v['assets'][0]),'response':v},'workingBytes':size,'seconds':time.monotonic()-started},ensure_ascii=False,indent=2)+'\n')
print(json.dumps({'nativeRTFD':25,'nativeDOCXPNG':1,'workingBytes':size,'seconds':time.monotonic()-started}))
