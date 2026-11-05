#!/usr/bin/env python3
"""Begrenzte Offline-Qualitätsprüfung; Sollwerte stammen aus Fixtures, nie PMT-Ausgaben."""
import argparse,collections,hashlib,html,json,os,re,runpy,shutil,subprocess,tempfile,zipfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--repo',type=Path,required=True);p.add_argument('--cli',type=Path,required=True);p.add_argument('--results',type=Path,required=True);a=p.parse_args()
a.results.mkdir(exist_ok=False);repo=a.repo;cli=a.cli
sha=lambda b:hashlib.sha256(b).hexdigest()
records=[]
def command(cmd,**kw):return subprocess.run(list(map(str,cmd)),capture_output=True,text=True,timeout=100,**kw)
def inventory(text,required):
    missing={v:n-text.count(v) for v,n in collections.Counter(required).items() if text.count(v)<n}
    if missing:raise AssertionError('missing inventory '+str(missing))
def archive(path,parts):
    with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as z:
        for n,v in parts.items():z.writestr(n,v)
with tempfile.TemporaryDirectory(prefix='pmt-quality-fixtures-') as tmp:
    root=Path(tmp);f=root/'fixtures';f.mkdir();out=root/'output';out.mkdir()
    shutil.copy(repo/'scripts/linux-probes/swift-core/fixtures.py',root/'fixtures.py');runpy.run_path(str(root/'fixtures.py'))
    png=(repo/'Tests/PoorMansTextCoreTests/Fixtures/WordProcessing/fixture.png').read_bytes();(f/'fixture.png').write_bytes(png)
    text='# QUALITYTITLE\n\nFIRSTTOKEN Grüße aus Köln.\n\n- LISTONETOKEN\n- LISTTWOTOKEN\n\n| Name | Value |\n|---|---|\n| CELLONETOKEN | 42 |\n| CELLTWOTOKEN | 17 |\n\n![IMAGEALTTOKEN](fixture.png)\n\nLASTTOKEN\n'
    (f/'source.md').write_text(text)
    common=['QUALITYTITLE','FIRSTTOKEN','Grüße','Köln','LISTONETOKEN','LISTTWOTOKEN','CELLONETOKEN','42','CELLTWOTOKEN','17','LASTTOKEN']
    cases=[]
    for ext in ('docx','odt','epub'):
        r=command(['pandoc',f/'source.md','-o',f/('source.'+ext)],cwd=f);assert r.returncode==0,r.stderr
        cases.append((ext,f/('source.'+ext),common,['FIRSTTOKEN','LISTONETOKEN','LISTTWOTOKEN','CELLONETOKEN','CELLTWOTOKEN','LASTTOKEN'],png,[]))
    cases += [('csv',f/'table.csv',['Name','Value','Größe','42','quoted, field','17'],['Name','Größe','quoted, field'],None,[]),('xlsx',f/'table.xlsx',['XLSXTOKEN','Value','Größe','42'],['XLSXTOKEN','Größe'],None,[]),('rtf',f/'encoding.rtf',['RTFMARKER','Größe','α'],['RTFMARKER','Größe','α'],None,[])]
    rtfd=f/'source.rtfd';rtfd.mkdir();(rtfd/'local.png').write_bytes(png);(rtfd/'TXT.rtf').write_bytes(br'{\rtf1\ansi BEFORETOKEN {\NeXTGraphic local.png \width16 \height12} AFTERTOKEN}')
    cases.append(('rtfd',rtfd,['BEFORETOKEN','AFTERTOKEN'],['BEFORETOKEN','AFTERTOKEN'],png,[]))
    (f/'source.mbox').write_text('From a@example.invalid Sat Jan  1 00:00:00 2022\nFrom: a@example.invalid\nTo: b@example.invalid\nSubject: One\nContent-Type: text/plain; charset=UTF-8\n\nMAILONETOKEN café.\n\nFrom b@example.invalid Sun Jan  2 00:00:00 2022\nFrom: b@example.invalid\nTo: a@example.invalid\nSubject: Two\nContent-Type: text/plain; charset=UTF-8\n\nMAILTWOTOKEN.\n')
    cases.append(('mbox',f/'source.mbox',['MAILONETOKEN','café','MAILTWOTOKEN'],['MAILONETOKEN','MAILTWOTOKEN'],None,[]))
    notes=''.join('<note><title>Note '+str(i)+'</title><content>'+html.escape('<en-note><p>'+v+'</p></en-note>')+'</content><created>20261018T051000Z</created></note>' for i,v in enumerate(['NOTEONETOKEN Grüße','NOTETWOTOKEN'],1))
    (f/'source.enex').write_text('<en-export>'+notes+'</en-export>');cases.append(('enex',f/'source.enex',['NOTEONETOKEN','Grüße','NOTETWOTOKEN'],['NOTEONETOKEN','NOTETWOTOKEN'],None,[]))
    ns='http://schemas.openxmlformats.org/';P=ns+'presentationml/2006/main';A=ns+'drawingml/2006/main';R=ns+'officeDocument/2006/relationships';REL=ns+'package/2006/relationships'
    parts={'[Content_Types].xml':f'<Types xmlns="{ns}package/2006/content-types"><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/></Types>','ppt/presentation.xml':f'<p:presentation xmlns:p="{P}" xmlns:r="{R}"><p:sldIdLst><p:sldId id="2" r:id="second"/><p:sldId id="1" r:id="first"/></p:sldIdLst></p:presentation>','ppt/_rels/presentation.xml.rels':f'<Relationships xmlns="{REL}"><Relationship Id="first" Type="{R}/slide" Target="slides/slide1.xml"/><Relationship Id="second" Type="{R}/slide" Target="slides/slide10.xml"/></Relationships>'}
    for name,token in [('slide10','SLIDEONETOKEN'),('slide1','SLIDETWOTOKEN')]:parts['ppt/slides/'+name+'.xml']=f'<p:sld xmlns:p="{P}" xmlns:a="{A}"><p:cSld><p:spTree><p:sp><p:txBody><a:p><a:r><a:t>{token}</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
    archive(f/'source.pptx',parts);cases.append(('pptx',f/'source.pptx',['SLIDEONETOKEN','SLIDETWOTOKEN'],['SLIDEONETOKEN','SLIDETWOTOKEN'],None,[]))
    def snapshot(path):return {str(x.relative_to(path) if path.is_dir() else x.name):sha(x.read_bytes()) for x in (path.rglob('*') if path.is_dir() else [path]) if x.is_file()}
    for name,source,required,ordered,asset,flags in cases:
        rec={'capability':name,'status':'FAIL'};records.append(rec);before=snapshot(source);dest=out/name
        r=command([cli,'--json','--report','--source-map','--pandoc','/usr/bin/pandoc',*flags,'-o',dest,'--',source]);rec['exit']=r.returncode
        try:
            j=json.loads(r.stdout);rec['diagnostics']=[d['code'] for d in j.get('diagnostics',[])];assert r.returncode==0,(r.stdout,r.stderr)
            docs=j.get('documents') or [];paths=[Path(d['markdownFile']) for d in docs] if docs else [Path(j['markdownFile'])]
            md='\n'.join(x.read_text() for x in paths);inventory(md,required)
            expected_cells={'csv':[['Name','Value'],['Größe','42'],['quoted, field','17']],'xlsx':[['XLSXTOKEN','Value'],['Größe','42']]}
            if name in expected_cells:
                rows=[[v.strip() for v in line.strip().strip('|').split('|')] for line in md.splitlines() if line.startswith('|') and not re.fullmatch(r'[| :\-]+',line)]
                assert rows==expected_cells[name],('cell inventory or order',rows)
            expected_diagnostics={'docx':['sourceMap.unavailable'],'odt':['sourceMap.unavailable'],'epub':['epub.flattened','sourceMap.unavailable'],'csv':[],'xlsx':[],'rtf':['sourceMap.unavailable'],'rtfd':['rtfd.layoutNotPreserved','sourceMap.unavailable'],'mbox':[],'enex':['html.structureSimplified','html.structureSimplified'],'pptx':['presentation.layoutNotPreserved']}
            assert collections.Counter(rec['diagnostics'])==collections.Counter(expected_diagnostics[name]),'diagnostics changed'
            positions=[md.index(x) for x in ordered];assert positions==sorted(positions),'order changed'
            assert snapshot(source)==before,'source changed'
            for e in j['outputFiles']:assert sha((dest/e['path']).read_bytes())==e['sha256'],'manifest mismatch'
            if asset is not None:assert any(x.read_bytes()==asset for x in dest.rglob('*') if x.is_file() and x.suffix=='.png'),'original image bytes missing'
            # Gegenprobe: fehlenden Solltext muss derselbe Prüfer ablehnen.
            try:inventory(md.replace(required[0],''),required)
            except AssertionError:pass
            else:raise AssertionError('loss control not detected')
            rec.update(status='PASS',checks=['inventory','order','source bytes','output hashes','loss control','diagnostics']+(['exact cells/rows'] if name in expected_cells else [])+(['original asset bytes'] if asset else []),markdown=md)
        except Exception as err:rec.update(error=str(err),stdout=r.stdout,stderr=r.stderr)
    version=command([cli,'--version']);summary={'cliSHA256':sha(cli.read_bytes()),'version':version.stdout.strip(),'cases':records}
    (a.results/'families.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
print(json.dumps({r['capability']:r['status'] for r in records}))
raise SystemExit(any(r['status']=='FAIL' for r in records))
