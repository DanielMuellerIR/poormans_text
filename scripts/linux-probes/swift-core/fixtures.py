from pathlib import Path
import json,zipfile,hashlib
p=Path(__file__).parent/'fixtures'
p.mkdir(exist_ok=True)
(p/'table.csv').write_text('Name,Value\nGröße,42\n"quoted, field",17\n',encoding='utf8')
(p/'notebook.ipynb').write_text(json.dumps({'nbformat':4,'nbformat_minor':5,'metadata':{'language_info':{'name':'python'}},'cells':[{'cell_type':'markdown','metadata':{},'source':['NOTEBOOKTOKEN Größe']},{'cell_type':'code','metadata':{},'source':['print("CODETOKEN")'],'outputs':[{'output_type':'stream','name':'stdout','text':['OUTPUTTOKEN\n']}],'execution_count':None}]}))
(p/'encoding.rtf').write_bytes(b'{\\rtf1\\ansi\\ansicpg1252 RTFMARKER Gr\\\'f6\\\'dfe \\u945?}')
(p/'picture.md').write_text('# DOCXTOKEN\n\nGröße with picture.\n\n![PIXELTOKEN](fixture.png)\n\n| A | B |\n|---|---|\n| CELLTOKEN | 42 |\n')
ns='http://schemas.openxmlformats.org/spreadsheetml/2006/main'
r='http://schemas.openxmlformats.org/officeDocument/2006/relationships'
parts={
'[Content_Types].xml': '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>',
'_rels/.rels': f'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="{r}/officeDocument" Target="xl/workbook.xml"/></Relationships>',
'xl/workbook.xml': f'<workbook xmlns="{ns}" xmlns:r="{r}"><sheets><sheet name="SheetToken" sheetId="1" r:id="rId1"/></sheets></workbook>',
'xl/_rels/workbook.xml.rels': f'<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="{r}/worksheet" Target="worksheets/sheet1.xml"/></Relationships>',
'xl/worksheets/sheet1.xml':f'<worksheet xmlns="{ns}"><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>XLSXTOKEN</t></is></c><c r="B1" t="inlineStr"><is><t>Value</t></is></c></row><row r="2"><c r="A2" t="inlineStr"><is><t>Größe</t></is></c><c r="B2"><v>42</v></c></row></sheetData></worksheet>'}
with zipfile.ZipFile(p/'table.xlsx','w',zipfile.ZIP_DEFLATED) as z:
 for n,s in parts.items():z.writestr(n,s)
(p/'invalid.ipynb').write_text('{invalid')
(p/'source-hashes.json').write_text(json.dumps({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in p.iterdir() if f.suffix in ['.csv','.xlsx','.ipynb','.rtf','.png']},indent=2))
