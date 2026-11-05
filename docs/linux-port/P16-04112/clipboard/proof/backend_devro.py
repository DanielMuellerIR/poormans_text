import pathlib,subprocess,json,os,hashlib,base64,time
r=pathlib.Path('/probe');helper='/helper';cli='/candidate/cli';guard='/candidate/poormans-text-process-guard';rows=[]
for source,options,env in [('source.heic',['--preview-frame','1'],{'PMT_BOUND_PREVIEW':'1'}),('pages.pdf',['--preview-page','2'],{'PMT_BOUND_PREVIEW':'1','PMT_BOUND_NO_INPUT':'1'})]:
 p=r/'fixtures'/source;b=p.read_bytes();out=subprocess.run([helper,cli,guard,str(p),*options],env={**os.environ,**env},capture_output=True,timeout=30);assert out.returncode==0,out.stderr
 v=json.loads(out.stdout)['preview'];data=base64.b64decode(v['png'],validate=True);assert hashlib.sha256(data).hexdigest()==v['sha256'];assert v['sourceIdentity']['sha256']==hashlib.sha256(b).hexdigest();assert max(v['width'],v['height'])<=1024
 rows.append({'source':source,'sourceSHA256':hashlib.sha256(b).hexdigest(),'preview':{k:x for k,x in v.items() if k!='png'}})
p=r/'fixtures/pages.pdf';out=subprocess.run([helper,cli,guard,str(p),'--pdf-ocr','off','--output',str(r/'proof'/('pdf-normal-'+str(time.time_ns())))],env={**os.environ,'PMT_BOUND_NO_INPUT':'1'},capture_output=True,timeout=30);assert out.returncode==0,out.stderr;v=json.loads(out.stdout);text=pathlib.Path(v['markdownFile']).read_text();assert 'PAGE ONE' in text and 'PAGE TWO' in text;rows.append({'normalPDF':v})
(r/'proof/backend-devro.json').write_text(json.dumps(rows,indent=2)+'\n');print('bound HEIC frame, normal PDF page2 preview and full PDF conversion PASS')
