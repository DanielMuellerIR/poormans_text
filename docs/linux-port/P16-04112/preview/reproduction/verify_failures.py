from pathlib import Path
import subprocess,os,json,time,signal,hashlib
root=Path(os.environ.get('PMT_PREVIEW_TEST_ROOT','/probe'));cli=os.environ.get('PMT_PREVIEW_TEST_CLI','/release/bin/poormans-text');env=dict(os.environ,LD_LIBRARY_PATH=os.environ.get('PMT_PREVIEW_TEST_LIBS','/release/lib'));source=root/'fixtures/large.png';cases=[];before=hashlib.sha256(source.read_bytes()).hexdigest()
def result(name,p,expected):
 stdout,stderr=p.communicate(timeout=40);v=json.loads(stdout);assert p.returncode==expected,(name,p.returncode,v,stderr.decode());cases.append({'case':name,'exit':p.returncode,'response':v});return v
p=subprocess.Popen([cli,'--json','--preview-frame','1','--timeout','0.001','--',str(source)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env);result('timeout',p,124)
p=subprocess.Popen([cli,'--json','--preview-frame','1','--',str(source)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env);time.sleep(.03);p.send_signal(signal.SIGINT);result('cancel',p,130)
for args in [['--preview-frame','0'],['--preview-frame','1','--preview-page','2'],['--preview-frame','1','--image-ocr','off']]:
 p=subprocess.Popen([cli,'--json',*args,'--',str(source)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env);result('usage-'+str(len(cases)),p,64)
assert hashlib.sha256(source.read_bytes()).hexdigest()==before
for case in cases:case['sourceSHA256']=before;case['sourceUnchanged']=True
(root/'results/failure-receipts.json').write_text(json.dumps(cases,indent=2)+'\n');print(json.dumps({'failureCases':len(cases),'passed':len(cases)}))
