import os,sys,json,time,signal,hashlib,resource,re
from pathlib import Path
sys.path.insert(0,'/probe')
from quality import Cells,measure,norm
import torch
from docling.datamodel.accelerator_options import AcceleratorDevice,AcceleratorOptions
from docling.datamodel.base_models import InputFormat
from docling.datamodel.pipeline_options import PdfPipelineOptions,LayoutObjectDetectionOptions,TableStructureOptions,TableFormerMode,TesseractCliOcrOptions,OcrMode
from docling.document_converter import DocumentConverter,PdfFormatOption,ImageFormatOption
ROOT=Path('/opt/docling');OUT=Path('/output');OUT.mkdir(exist_ok=True)
source=Path('/input')/sys.argv[1]
def sha(p):return hashlib.file_digest(p.open('rb'),'sha256').hexdigest()
before=sha(source);started=time.monotonic()
torch.set_num_threads(2);torch.set_num_interop_threads(1)
layout=LayoutObjectDetectionOptions.from_preset('layout_heron_default')
layout.model_spec=layout.model_spec.model_copy(update={'revision':'8f39ad3c0b4c58e9c2d2c84a38465abf757272d8'})
options=PdfPipelineOptions(artifacts_path=ROOT/'models')
options.accelerator_options=AcceleratorOptions(device=AcceleratorDevice.CPU,num_threads=2)
options.layout_options=layout;options.do_table_structure=True
options.table_structure_options=TableStructureOptions(mode=TableFormerMode.ACCURATE,do_cell_matching=True)
options.do_ocr=source.suffix=='.png';options.enable_remote_services=False
if options.do_ocr:options.ocr_options=TesseractCliOcrOptions(lang=['eng'],mode=OcrMode.FULL_PAGE)
converter=DocumentConverter(allowed_formats=[InputFormat.PDF,InputFormat.IMAGE],format_options={InputFormat.PDF:PdfFormatOption(pipeline_options=options),InputFormat.IMAGE:ImageFormatOption(pipeline_options=options)})
result=converter.convert(source,max_num_pages=1,max_file_size=10*1024**2)
md=result.document.export_to_markdown();document=result.document.export_to_dict()
(OUT/(source.stem+'.md')).write_text(md);(OUT/(source.stem+'.json')).write_text(json.dumps(document,indent=2,ensure_ascii=False)+'\n')
tables=[]
for table in document.get('tables',[]):
 cells=[]
 for cell in table['data']['table_cells']:
  cells.append({'row':cell['start_row_offset_idx'],'column':cell['start_col_offset_idx'],'rowspan':cell['row_span'],'colspan':cell['col_span'],'text':cell['text']})
 tables.append(cells)
if source.suffix=='.pdf' or source.name.endswith('-render.png'):
 reference=json.loads(Path('/input/selected-reference.json').read_text())[source.name.replace('-render.png','.pdf')];expected=[]
 for e in reference['elements']:
  if e['category']=='Table':
   parser=Cells();parser.feed(e['content']['html']);expected.append(parser.cells)
else:expected=[[{'row':r,'column':c,'rowspan':1,'colspan':last-c+1,'text':text} for r,c,last,text in [(0,0,1,'MERGED HEADER'),(0,2,2,'TOTAL'),(1,0,0,'A1'),(1,1,1,'B1'),(1,2,2,'C1'),(2,0,0,'A2'),(2,1,1,'B2'),(2,2,2,'C2')]]]
evidence={'source':source.name,'sourceSHA256':before,'sourceUnchanged':sha(source)==before,'seconds':time.monotonic()-started,'status':str(result.status),'expectedTables':len(expected),'predictedTables':len(tables),'tables':tables,'quality':measure(expected[0],tables[0]) if len(expected)==len(tables)==1 else None,'markdownSHA256':sha(OUT/(source.stem+'.md')),'jsonSHA256':sha(OUT/(source.stem+'.json')),'maxRSSKiB':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'memoryPeakBytes':int(Path('/sys/fs/cgroup/memory.peak').read_text()),'OCR':'system Tesseract eng/full-page' if options.do_ocr else 'off; digital PDF words','remoteServices':False,'manualROIOrThresholdChanges':False,'layoutPreset':'layout_heron_default','tableMode':'accurate','markdownContainsExplicitSpans':bool(re.search(r'(colspan|rowspan)\s*=',md))}
assert evidence['sourceUnchanged']
(OUT/(source.stem+'-result.json')).write_text(json.dumps(evidence,indent=2,ensure_ascii=False)+'\n')
print(json.dumps({k:v for k,v in evidence.items() if k!='tables'},ensure_ascii=False),flush=True)
