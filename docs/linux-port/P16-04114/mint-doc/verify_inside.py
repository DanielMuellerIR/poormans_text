from pathlib import Path
import os,json,subprocess,hashlib,re,time
root=Path(__file__).resolve().parent;runtime=root/'extracted/usr/lib/poormans-text';cli=runtime/'bin/poormans-text';pandoc=root/'pandoc';out=root/'outputs';out.mkdir(exist_ok=True)
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
assert sha(cli)=='8abc9197eeced8df043d788e349acb553bd86dd81546a6fda1faf15a93bac0cb'
assert sha(pandoc)=='5a953bcbcdc7c36fcb0c263fbb09db8c7b84cfa9ca58e48e321d7edf857a7ee7'
helper=runtime/'bin/PoorMansText_PoorMansTextCore.resources/LinuxBackends/legacy_doc.py';text=helper.read_text();assert 'NEVER_EXECUTE' in text and 'NO_UPDATE' in text and 'ALWAYS_EXECUTE' not in text
version=subprocess.run(['/usr/bin/libreoffice','--headless','--version'],capture_output=True,text=True,timeout=10)
env=dict(os.environ,LD_LIBRARY_PATH=str(runtime/'lib'));catalog=subprocess.run([str(cli),'--json','--formats','--pandoc',str(pandoc)],capture_output=True,text=True,env=env,timeout=20);assert catalog.returncode==0,(catalog.stdout,catalog.stderr);row=next(x for x in json.loads(catalog.stdout)['formats'] if x['format']=='doc');assert row['available'],row
normal=root/'Tests/PoorMansTextCoreTests/Fixtures/WordProcessing/libreoffice.doc';rich=root/'docs/linux-port/P16-04112/clipboard/samples/RichAutoOpen.doc';originalPNG=root/'Tests/PoorMansTextCoreTests/Fixtures/WordProcessing/fixture.png';cases={}
for name,source,markers in [('normal',normal,['Fixture heading ä','First list item','Second list item','Äpfel','Birnen','Grüße aus Köln','Footnote content remains readable.']),('rich-safe',rich,['PMT UNO DOC ä Grüße','First controlled list item','Second controlled list item','IMAGE-FOLLOWS'])]:
 before=sha(source);start=time.monotonic();p=subprocess.run([str(cli),'--json','--report','--source-map','--pandoc',str(pandoc),'--output',str(out/name),str(source)],capture_output=True,text=True,env=env,timeout=30);v=json.loads(p.stdout);(root/(name+'-raw.json')).write_text(json.dumps({'exit':p.returncode,'response':v,'stderr':p.stderr,'LibreOfficeVersion':version.stdout.strip()},ensure_ascii=False,indent=2)+'\n');assert p.returncode==0,(name,p.returncode,v,p.stderr);md=Path(v['markdownFile']).read_text();normalized=re.sub(r'\s+',' ',md)
 for marker in markers:assert marker in normalized,(name,marker,md)
 if name=='rich-safe':
  for marker in markers:assert normalized.count(marker)==1,(marker,md)
 assert len(v['assets'])==1 and Path(v['assets'][0]).read_bytes()==originalPNG.read_bytes()
 assert len(re.findall(r'^(?:- |• )',md,re.M))==2,md
 assert any(d['code']=='legacyWord.potentialLoss' for d in v.get('diagnostics',[]))
 assert sha(source)==before and v['sourceIdentity']['sha256']==before
 for item in v['outputFiles']:
  f=out/name/item['path'];assert f.stat().st_size==item['byteCount'] and sha(f)==item['sha256']
 report=json.loads(Path(v['reportFile']).read_text());assert report['source']['sha256']==before
 for item in report['outputs']:
  f=out/name/item['path'];assert f.stat().st_size==item['byteCount'] and sha(f)==item['sha256']
 assert not list(root.rglob('*.sentinel')),'unexpected macro sentinel'
 cases[name]={'exit':p.returncode,'seconds':time.monotonic()-start,'sourceSHA256':before,'sourceUnchanged':True,'originalPNG_SHA256':sha(originalPNG),'assetSHA256':sha(v['assets'][0]),'markdown':md,'response':v,'stderr':p.stderr}
(root/'doc-results.json').write_text(json.dumps({'native':True,'host':os.uname().nodename,'LibreOfficeVersion':version.stdout.strip(),'LibreOfficeVersionStatus':version.returncode,'docCatalog':row,'safeHelperSHA256':sha(helper),'productUsesMacroNeverAndNoUpdate':True,'noUnsafeControlExecuted':True,'macroSafetyIndependentlyRequalified':False,'cases':cases},ensure_ascii=False,indent=2)+'\n');print(json.dumps({'nativeLegacyDocCases':len(cases),'passed':len(cases),'LibreOffice':version.stdout.strip()}))
