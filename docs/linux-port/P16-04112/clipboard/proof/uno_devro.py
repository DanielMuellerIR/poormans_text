import pathlib,subprocess,json,os,hashlib,time
r=pathlib.Path('/probe');source=r/'fixtures/RichAutoOpen.doc';before=hashlib.sha256(source.read_bytes()).hexdigest();started=time.monotonic()
p=subprocess.run(['/helper','/candidate/cli','/candidate/poormans-text-process-guard',str(source),'--image-ocr','off','--output',str(r/'proof'/('uno-normal-'+str(time.time_ns())))],env={**os.environ,'PMT_BOUND_NO_INPUT':'1'},capture_output=True,timeout=30)
assert p.returncode==0,(p.stdout,p.stderr);v=json.loads(p.stdout);text=pathlib.Path(v['markdownFile']).read_text();assert len(text)>30 and 'AUTO_OPEN' not in text
assert hashlib.sha256(source.read_bytes()).hexdigest()==before
(r/'proof/uno-devro.json').write_text(json.dumps({'sourceSHA256':before,'sourceUnchanged':True,'seconds':time.monotonic()-started,'response':v,'markdownBytes':len(text.encode())},indent=2)+'\n');print('normal safe UNO DOC with devRO PASS')
