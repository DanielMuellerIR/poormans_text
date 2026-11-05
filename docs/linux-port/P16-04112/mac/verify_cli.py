"""Native CLI-Smokes; nur nach ausdrücklicher Übergabe des aktuellen Buildstands starten."""
import argparse,hashlib,json,pathlib,subprocess,unicodedata,zipfile,xml.etree.ElementTree as ET
P=pathlib.Path
sha=lambda data:hashlib.sha256(data).hexdigest()

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--cli',required=True,type=P);parser.add_argument('--source',required=True,type=P);parser.add_argument('--output',required=True,type=P);args=parser.parse_args()
 cli=args.cli.resolve();source=args.source.resolve();out=args.output.resolve();out.mkdir(mode=0o700)
 fixtures=out/'fixtures';fixtures.mkdir();records=[]
 csv=fixtures/unicodedata.normalize('NFC','Grüße é & Zeichen.csv');csv.write_text('Name,Notiz,Wert\r\n"Müller, Ä","Er sagte ""Grüß dich""",12\r\nβ,"erste\nzweite",7\r\n',encoding='utf-8')
 docx=fixtures/unicodedata.normalize('NFC',"Grüße é & 'Bild'.docx")
 original=source/'Tests/PoorMansTextCoreTests/Fixtures/WordProcessing/pandoc.docx';png=(source/'Tests/PoorMansTextCoreTests/Fixtures/WordProcessing/fixture.png').read_bytes()
 with zipfile.ZipFile(original) as archive,zipfile.ZipFile(docx,'w',zipfile.ZIP_DEFLATED) as destination:
  expected_docx=[node.text.strip() for node in ET.fromstring(archive.read('word/document.xml')).iter('{http://schemas.openxmlformats.org/wordprocessingml/2006/main}t') if node.text and len(node.text.strip())>2]
  for item in archive.infolist():destination.writestr(item.filename,archive.read(item.filename))
 for index,item in enumerate([csv,docx]):
  initial=item.read_bytes();destination=out/f'result-{index}'
  run=subprocess.run([str(cli),'--json','--report','--source-map','-o',str(destination),'--',str(item)],capture_output=True,timeout=120)
  response=json.loads(run.stdout);record={'format':item.suffix[1:],'exit':run.returncode,'sourceSHA256':sha(initial),'sourceUnchanged':item.read_bytes()==initial,'filenameNFC':unicodedata.is_normalized('NFC',item.name),'checks':{},'outputFiles':[]}
  assert run.returncode==0 and response.get('ok') is True,run.stderr.decode(errors='replace')
  text=P(response['markdownFile']).read_text(encoding='utf-8');record['checks']['markdownUTF8']=True
  if item==csv:
   record['checks']['allCSVValues']=all(token in text for token in ['Name','Notiz','Wert','Müller, Ä','Er sagte "Grüß dich"','12','β','erste','zweite','7'])
   record['checks']['nineMappings']=len(response['sourceMappings'])==9
  else:
   record['checks']['PNGByteIdentity']=any(P(asset).read_bytes()==png for asset in response['assets'])
   record['checks']['allDOCXTextRuns']=all(token in text for token in expected_docx)
  root=P(response['outputDirectory']);data=P(response['markdownFile']).read_bytes()
  for entry in response['outputFiles']:
   path=root/entry['path'];content=path.read_bytes();assert sha(content)==entry['sha256'] and len(content)==entry['byteCount'];record['outputFiles'].append({'path':entry['path'],'byteCount':len(content),'sha256':sha(content)})
  for mapping in response.get('sourceMappings',[]):
   position=mapping['output'];mapped=(root/position['file']).read_bytes();start=position['utf8Offset'];length=position['utf8Length'];assert start+length<=len(mapped);mapped[:start].decode('utf-8');mapped[start:start+length].decode('utf-8')
  assert record['sourceUnchanged'] and all(record['checks'].values());records.append(record)
 result={'cliSHA256':sha(cli.read_bytes()),'version':subprocess.check_output([str(cli),'--version'],text=True).strip(),'cases':records};(out/'cli.json').write_text(json.dumps(result,ensure_ascii=False,indent=2)+'\n');print(json.dumps(result,ensure_ascii=False))
if __name__=='__main__':main()
