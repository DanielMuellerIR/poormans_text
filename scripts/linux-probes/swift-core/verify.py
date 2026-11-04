#!/usr/bin/env python3
from pathlib import Path
import argparse,hashlib,json
p=argparse.ArgumentParser();p.add_argument('probe',type=Path);p.add_argument('output',type=Path);a=p.parse_args()
expected={'table.csv':('table.md',{'Name':1,'Value':1,'Größe':1,'42':1,'quoted, field':1,'17':1}), 'table.xlsx':('table.md',{'SheetToken':1,'XLSXTOKEN':1,'Größe':1,'42':1}), 'notebook.ipynb':('notebook.md',{'NOTEBOOKTOKEN':1,'CODETOKEN':1,'OUTPUTTOKEN':1,'Größe':1}), 'picture.docx':('picture.md',{'DOCXTOKEN':1,'CELLTOKEN':1,'Größe':1,'![PIXELTOKEN]':1}), 'encoding.rtf':('encoding.md',{'RTFMARKER':1,'Größe':1,'α':1})}
for source,(name,tokens) in expected.items():
 d=a.output/source; text=(d/name).read_text()
 for token,count in tokens.items():assert text.count(token)==count,(source,token,text.count(token),count)
 report=json.loads((d/'conversion-report.json').read_text());actual=hashlib.sha256((a.probe/'fixtures'/source).read_bytes()).hexdigest()
 assert report['source']['sha256']==actual,(source,'source hash')
 if source=='picture.docx':
  images=list((d/'images').iterdir());assert len(images)==1
  assert images[0].read_bytes()==(a.probe/'fixtures/fixture.png').read_bytes()
 print(source+': text counts, source hash'+(', image bytes' if source=='picture.docx' else '')+' PASS')
for name,digest in json.loads((a.probe/'fixtures/source-hashes.json').read_text()).items():assert hashlib.sha256((a.probe/'fixtures'/name).read_bytes()).hexdigest()==digest,(name,'source changed')
print('Sources unchanged PASS')
