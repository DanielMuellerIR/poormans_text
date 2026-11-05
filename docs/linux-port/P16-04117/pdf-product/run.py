from pathlib import Path
from PIL import Image
import subprocess,hashlib,json,runpy
root=Path('/work');sha=lambda p:hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
Image.open(root/'source.png').convert('RGB').save(root/'scanned.pdf',resolution=150)
runpy.run_path('/work/make_mixed.py')
rows=[]
for name in ('scanned','mixed'):
 source=root/(name+'.pdf');before=sha(source);output=root/(name+'-output')
 p=subprocess.run(['/runtime/bin/poormans-text','--json','--report','--ocr-method','structured','--ocr-language','en','--pdf-ocr','always','--output',str(output),'--',str(source)],capture_output=True,text=True,timeout=150)
 (root/(name+'-response.json')).write_text(p.stdout);(root/(name+'-stderr')).write_text(p.stderr)
 assert p.returncode==0,(name,p.stdout,p.stderr)
 j=json.loads(p.stdout);md=Path(j['markdownFile']).read_text();codes=[d['code'] for d in j.get('diagnostics',[])]
 assert sha(source)==before and j['assets']
 for entry in j['outputFiles']:assert sha(output/entry['path'])==entry['sha256']
 if name=='scanned':assert 'ocr.structuredApplied' in codes
 else:assert md.count('DIGITAL ORIGINAL MUST SURVIVE 7319')==1
 rows.append({'case':name,'exit':p.returncode,'sourceSHA256':before,'sourceUnchanged':True,'outputManifestPassed':True,'assetsRetained':True,'digitalOriginalExactlyOnce':True if name=='mixed' else None,'diagnostics':codes})
(root/'summary.json').write_text(json.dumps({'cliSHA256':sha(Path('/runtime/bin/poormans-text')),'cases':rows,'scope':'Actual final product PDF integration, not semantic completeness'},indent=2)+'\n')
print(json.dumps(rows,indent=2))
