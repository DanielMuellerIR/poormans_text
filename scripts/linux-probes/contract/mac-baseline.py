import pathlib,tempfile,subprocess,json,hashlib,zipfile,base64,shutil,os,time,signal,sys
repo=pathlib.Path(sys.argv[1]) if len(sys.argv)>1 else pathlib.Path.cwd(); binary=repo/'poormans-text'
root=pathlib.Path(tempfile.mkdtemp(prefix='pmt-p01-'))
records={'repoHead':subprocess.check_output(['git','-C',str(repo),'rev-parse','HEAD'],text=True).strip(),'binarySHA256':hashlib.sha256(binary.read_bytes()).hexdigest(),'macOS':subprocess.check_output(['sw_vers','-productVersion'],text=True).strip(),'arch':subprocess.check_output(['uname','-m'],text=True).strip(),'fixtureRoot':str(root),'cases':{}}
env=dict(os.environ,PATH='/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin')
def run(name,args,expected=0):
    result=subprocess.run([str(binary)]+args,capture_output=True,timeout=30,env=env)
    record={'args':args,'exit':result.returncode,'expectedExit':expected,'stdout':result.stdout.decode('utf8'),'stderr':result.stderr.decode('utf8')}
    try: record['json']=json.loads(record['stdout'])
    except ValueError: pass
    records['cases'][name]=record
    return record
try:
    run('catalog',['--formats','--json']);run('help',['--help'])
    (root/'table ä: probe.csv').write_text('Name,Value\nAlpha,1\nBéta,2\n',encoding='utf8')
    (root/'encoding.rtf').write_bytes(b"{\\rtf1\\ansi\\ansicpg1252 Gr\\'fc\\'dfe \\u945?}")
    (root/'notebook.ipynb').write_text(json.dumps({'nbformat':4,'nbformat_minor':5,'metadata':{},'cells':[{'cell_type':'markdown','metadata':{},'source':['Notebook alpha ä']},{'cell_type':'code','metadata':{},'execution_count':1,'source':['print(2)'],'outputs':[{'output_type':'stream','name':'stdout','text':['2\n']}]}]}))
    def zipwrite(name,entries):
        with zipfile.ZipFile(root/name,'w',zipfile.ZIP_DEFLATED) as f:
            for key,val in entries.items(): f.writestr(key,val)
    zipwrite('sheet.xlsx',{
    '[Content_Types].xml':'<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
    '_rels/.rels':'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>',
    'xl/workbook.xml':'<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Data" sheetId="1" r:id="rId1"/></sheets></workbook>',
    'xl/_rels/workbook.xml.rels':'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
    'xl/worksheets/sheet1.xml':'<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Alpha</t></is></c><c r="B1"><v>1</v></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>Béta</t></is></c><c r="B2"><v>2</v></c></row></sheetData></worksheet>'})
    # Referenz-DOCX stammt aus dem bestehenden, weitergebbaren Korpus und enthält ein Bild.
    fixture=repo/'Tests/PoorMansTextCoreTests/Fixtures/WordProcessing/pandoc.docx'
    shutil.copyfile(fixture,root/'picture.docx')
    (root/'mail.mbox').write_text('From a@example.invalid Sat Jan  1 00:00:00 2022\nFrom: a@example.invalid\nTo: b@example.invalid\nSubject: One\nContent-Type: text/plain; charset=utf-8\n\nMessage alpha\n\nFrom a@example.invalid Sun Jan  2 00:00:00 2022\nFrom: a@example.invalid\nTo: b@example.invalid\nSubject: Two\nContent-Type: text/plain; charset=utf-8\n\nMessage beta\n')
    (root/'notes.enex').write_text('<?xml version="1.0"?><en-export><note><title>One</title><content><![CDATA[<?xml version="1.0"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note>Note alpha</en-note>]]></content></note><note><title>Two</title><content><![CDATA[<?xml version="1.0"?><!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd"><en-note>Note beta</en-note>]]></content></note></en-export>')
    expected={'table ä: probe.csv':['Alpha','Béta','1','2'],'sheet.xlsx':['Alpha','Béta','1','2'],'notebook.ipynb':['Notebook alpha ä','print(2)','2'],'encoding.rtf':['Grüße','α'],'mail.mbox':['Message alpha','Message beta'],'notes.enex':['Note alpha','Note beta']}
    for i,name in enumerate(['table ä: probe.csv','sheet.xlsx','notebook.ipynb','encoding.rtf','picture.docx','mail.mbox','notes.enex']):
        source=root/name; before=hashlib.sha256(source.read_bytes()).hexdigest()
        record=run(name,['--progress','--json','--report','--output',str(root/('out'+str(i))),'--',str(source)])
        record['sourceUnchanged']=hashlib.sha256(source.read_bytes()).hexdigest()==before
        record['sourceSHA256']=before
        obj=record.get('json',{})
        if obj.get('ok'):
            out=pathlib.Path(obj['outputDirectory']); record['tree']={str(p.relative_to(out)): {'bytes':p.stat().st_size,'sha256':hashlib.sha256(p.read_bytes()).hexdigest()} for p in out.rglob('*') if p.is_file()}
            record['markdown']={str(p.relative_to(out)):p.read_text() for p in out.rglob('*.md')}
            content='\n'.join(record['markdown'].values())
            record['expectedMarkersPresent']={marker:marker in content for marker in expected.get(name,[])}
            if obj.get('reportFile'): record['report']=json.loads(pathlib.Path(obj['reportFile']).read_text())
    run('missing-input',['--json','--',str(root/'absent.csv')],66)
    run('missing-tool',['--json','--pandoc',str(root/'not-pandoc'),'--',str(root/'encoding.rtf')],69)
    run('invalid-call',['--json','--stdout','--',str(root/'encoding.rtf')],64)
    run('collision',['--json','--output',str(root/'out0'),'--',str(root/'table ä: probe.csv')],73)
    run('collection-stdout',['--stdout','--',str(root/'mail.mbox')],64)
    # Abbruch wird an der realen CLI angefordert; Nachkommenprüfung ist eigene P03-Abnahme.
    large=root/'large.csv';large.write_text('A,B\n'+'alpha,beta\n'*500000)
    process=subprocess.Popen([str(binary),'--progress','--json','--output',str(root/'cancel-out'),'--',str(large)],stdout=subprocess.PIPE,stderr=subprocess.PIPE,env=env)
    try:
        time.sleep(.03);process.send_signal(signal.SIGTERM)
        stdout,stderr=process.communicate(timeout=30)
    finally:
        if process.poll() is None:
            process.kill()
            process.communicate(timeout=5)
    records['cases']['cancel']={'exit':process.returncode,'stdout':stdout.decode(),'stderr':stderr.decode(),'outputPublished':(root/'cancel-out').exists(),'signal':'SIGTERM','descendantCleanupVerified':False}
finally:
    shutil.rmtree(root)
    records['fixtureCleanup']=not root.exists()
    print(json.dumps(records,ensure_ascii=False,indent=2))
