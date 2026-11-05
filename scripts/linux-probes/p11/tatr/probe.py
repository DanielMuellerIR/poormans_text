"""Isolierter P11-Ausschlussversuch; kein Produktadapter und keine Layoutbehauptung."""
import os,sys,json,hashlib,time,subprocess,csv,io,copy,signal,unicodedata,resource
from pathlib import Path
from html.parser import HTMLParser
from collections import Counter
import xml.etree.ElementTree as ET
import torch
from PIL import Image,ImageDraw
from safetensors.torch import load_file
from transformers import TableTransformerConfig,TableTransformerForObjectDetection,DetrImageProcessor
sys.path.insert(0,'/opt/p11');import postprocess
ROOT=Path('/opt/p11');OUT=Path('/output');OUT.mkdir(exist_ok=True)
torch.set_num_threads(2);torch.set_num_interop_threads(1)
START=time.monotonic();MODELS={};LOADS=[]
def sha(path):
 with open(path,'rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def norm(text):return ' '.join(unicodedata.normalize('NFC',text).split())
def timeout(_signum,_frame):raise TimeoutError('120s page timeout')
signal.signal(signal.SIGALRM,timeout)
for task in ['detection','structure-recognition']:
 path=ROOT/'models'/('table-transformer-'+task);started=time.monotonic()
 config=TableTransformerConfig.from_pretrained(path,local_files_only=True)
 published_backbone=config.use_pretrained_backbone;config.use_pretrained_backbone=False
 model=TableTransformerForObjectDetection(config).cpu()
 state=load_file(path/'model.safetensors',device='cpu')
 model_keys=set(model.state_dict());checkpoint_keys=set(state)
 missing=sorted(model_keys-checkpoint_keys);extra=sorted(checkpoint_keys-model_keys)
 if missing:raise RuntimeError(json.dumps({'strictStateFailed':task,'missing':missing}))
 from transformers.models.table_transformer.modeling_table_transformer import TableTransformerFrozenBatchNorm2d
 counters=[]
 for key in extra:
  parent,_,name=key.rpartition('.')
  if name!='num_batches_tracked' or not isinstance(model.get_submodule(parent),TableTransformerFrozenBatchNorm2d) or state[key].ndim!=0 or state[key].dtype!=torch.int64:raise RuntimeError('Unrecognized checkpoint key '+key)
  counters.append({'key':key,'value':int(state[key])})
 loaded=model.load_state_dict(state,strict=True);del state
 assert not loaded.missing_keys and not loaded.unexpected_keys
 model.eval();processor=DetrImageProcessor.from_pretrained(path,local_files_only=True)
 MODELS[task]=(model,processor)
 LOADS.append({'task':task,'publishedPretrainedBackbone':published_backbone,'effectivePretrainedBackbone':config.use_pretrained_backbone,'modelKeys':len(model_keys),'checkpointKeys':len(checkpoint_keys),'strictState':True,'officialFrozenBatchNormTrainingCounters':counters,'seconds':time.monotonic()-started,'sha256':sha(path/'model.safetensors')})
 print('STRICT_LOAD',json.dumps(LOADS[-1]),flush=True)
(OUT/'loads.json').write_text(json.dumps(LOADS,indent=2))
def infer(image,task):
 model,processor=MODELS[task]
 with torch.inference_mode():
  result=model(**processor(images=image,return_tensors='pt'))
  boxes=processor.post_process_object_detection(result,threshold=.5,target_sizes=torch.tensor([[image.height,image.width]]))[0]
 return [{'label':int(label),'score':float(score),'bbox':[float(v) for v in box]} for label,score,box in zip(boxes['labels'],boxes['scores'],boxes['boxes'])]
def tokens_pdf(path,prefix):
 subprocess.run(['pdftotext','-bbox-layout',str(path),str(prefix)+'.html'],check=True,timeout=30)
 xml=ET.parse(str(prefix)+'.html');words=[];tag=lambda e:e.tag.rsplit('}',1)[-1]
 for block_no,block in enumerate(e for e in xml.iter() if tag(e)=='block'):
  for line_no,line in enumerate(e for e in block.iter() if tag(e)=='line'):
   for word_no,word in enumerate(e for e in line if tag(e)=='word'):
    words.append({'bbox':[float(word.attrib[v])*2 for v in ['xMin','yMin','xMax','yMax']],'text':word.text or '', 'block_num':block_no,'line_num':line_no,'span_num':word_no})
 return words
def tokens_ocr(path):
 p=subprocess.run(['tesseract',str(path),'stdout','-l','eng','--psm','3','tsv'],capture_output=True,text=True,check=True,timeout=30)
 words=[]
 for v in csv.DictReader(io.StringIO(p.stdout),delimiter='\t'):
  if v['text'].strip() and float(v['conf'])>=0:
   x,y,w,h=[int(v[k]) for k in ['left','top','width','height']]
   words.append({'bbox':[x,y,x+w,y+h],'text':v['text'],'block_num':int(v['block_num']),'line_num':int(v['par_num'])*10000+int(v['line_num']),'span_num':int(v['word_num'])})
 return words
def overlap(word,box):
 x,y,X,Y=word;left,top,right,bottom=box
 return max(0,min(X,right)-max(x,left))*max(0,min(Y,bottom)-max(y,top))/max(1,(X-x)*(Y-y))
class Cells(HTMLParser):
 def __init__(self):super().__init__();self.row=-1;self.col=0;self.cells=[];self.current=None;self.occupied=set()
 def handle_starttag(self,tag,attrs):
  if tag=='tr':self.row+=1;self.col=0
  if tag in ('td','th'):
   while (self.row,self.col) in self.occupied:self.col+=1
   a=dict(attrs);rs=int(a.get('rowspan',1));cs=int(a.get('colspan',1));self.current={'row':self.row,'column':self.col,'rowspan':rs,'colspan':cs,'text':''}
   for row in range(self.row,self.row+rs):
    for col in range(self.col,self.col+cs):self.occupied.add((row,col))
   self.col+=cs
 def handle_data(self,data):
  if self.current is not None:self.current['text']+=data
 def handle_endtag(self,tag):
  if tag in ('td','th') and self.current is not None:self.current['text']=norm(self.current['text']);self.cells.append(self.current);self.current=None

def measure(expected,predicted):
 expected=sorted(expected,key=lambda v:(v['row'],v['column']));predicted=sorted(predicted,key=lambda v:(v['row'],v['column']))
 pos=lambda c:(c['row'],c['column']);p={pos(c):c for c in predicted}
 cells=[]
 for e in expected:
  c=p.get(pos(e));cells.append({'expected':e,'predicted':c,'textExact':c is not None and norm(c['text'])==norm(e['text']),'spanExact':c is not None and (c['rowspan'],c['colspan'])==(e['rowspan'],e['colspan'])})
 ewords=Counter(w for c in expected for w in norm(c['text']).split());pwords=Counter(w for c in predicted for w in norm(c['text']).split())
 return {'expectedCells':len(expected),'predictedCells':len(predicted),'textExactAtCell':sum(c['textExact'] for c in cells),'spansExactAtCell':sum(c['spanExact'] for c in cells),'expectedMergedCells':sum(c['rowspan']>1 or c['colspan']>1 for c in expected),'mergedExactAtCell':sum(c['spanExact'] for c in cells if c['expected']['rowspan']>1 or c['expected']['colspan']>1),'orderedCellTextExact': [norm(c['text']) for c in expected]==[norm(c['text']) for c in predicted],'expectedWordCount':sum(ewords.values()),'missingWords':list((ewords-pwords).elements()),'extraWords':list((pwords-ewords).elements()),'cellDetails':cells}
def run(source):
 signal.alarm(120);started=time.monotonic();path=Path('/input')/source;prefix=OUT/path.stem
 if path.suffix=='.pdf':
  subprocess.run(['pdftoppm','-f','1','-singlefile','-r','144','-png',str(path),str(prefix)],check=True,timeout=30);image=Image.open(str(prefix)+'.png').convert('RGB');words=tokens_pdf(path,prefix);token_source='Poppler bbox-layout; points*2 at144dpi'
 else:image=Image.open(path).convert('RGB');words=tokens_ocr(path);token_source='Tesseract psm3 eng, unmodified image'
 detections=infer(image,'detection');tables=[];overlay=image.copy();draw=ImageDraw.Draw(overlay)
 for table_no,det in enumerate(detections):
  if det['label']==1:raise RuntimeError('Rotated table detected; no untested rotation adapter in bounded probe')
  box=[det['bbox'][0]-20,det['bbox'][1]-20,det['bbox'][2]+20,det['bbox'][3]+20]
  crop=image.crop(box);crop.save(str(prefix)+f'-table{table_no}.png');tokens=[]
  for word in words:
   if overlap(word['bbox'],box)>=.5:
    token=copy.deepcopy(word);token['bbox']=[word['bbox'][0]-box[0],word['bbox'][1]-box[1],word['bbox'][2]-box[0],word['bbox'][3]-box[1]];tokens.append(token)
  objects=infer(crop,'structure-recognition');class_map=MODELS['structure-recognition'][0].config.id2label
  table_obj=next((o for o in objects if class_map[o['label']]=='table'),None)
  if table_obj is None:tables.append({'detection':det,'structureObjects':objects,'error':'No structure table class'});continue
  table_obj['page_num']=0
  structures,cells,confidence=postprocess.objects_to_cells(table_obj,objects,tokens,class_map,{v:.5 for v in class_map.values()})
  simple=[{'row':min(c['row_nums']),'column':min(c['column_nums']),'rowspan':len(c['row_nums']),'colspan':len(c['column_nums']),'text':c['cell_text'],'bbox':c['bbox']} for c in cells]
  used_tokens=[s for cell in cells for s in cell.get('spans',[])];assigned=Counter((s['block_num'],s['line_num'],s['span_num']) for s in used_tokens)
  table={'detection':det,'cropBox':box,'structureObjects':objects,'cells':simple,'confidence':confidence,'tableInputTokens':len(tokens),'assignedTokenCount':len(used_tokens),'unassignedTokens':[w for w in tokens if (w['block_num'],w['line_num'],w['span_num']) not in assigned],'multiplyAssignedTokenKeys':[list(k) for k,v in assigned.items() if v>1]}
  for c in simple:
   x,y,X,Y=c['bbox'];draw.rectangle([x+box[0],y+box[1],X+box[0],Y+box[1]],outline='red',width=2)
  tables.append(table)
 result={'source':source,'sourceSHA256':sha(path),'renderSHA256':sha(str(prefix)+'.png') if path.suffix=='.pdf' else sha(path),'imageSize':list(image.size),'tokenSource':token_source,'pageWordTokens':len(words),'detections':detections,'tables':tables,'seconds':time.monotonic()-started,'pageLayoutReadingOrderClaim':False,'maxRSSKiB':resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,'cgroupMemoryPeakBytes':Path('/sys/fs/cgroup/memory.peak').read_text().strip()}
 if path.suffix=='.pdf':
  gt=json.loads(Path('/input/selected-reference.json').read_text())[source];html=[e['content']['html'] for e in gt['elements'] if e['category']=='Table'];expected=[]
  for code in html:parser=Cells();parser.feed(code);expected.append(parser.cells)
  result['expectedTables']=len(expected)
  if len(expected)==1 and len(tables)==1 and 'cells' in tables[0]:result['quality']=measure(expected[0],tables[0]['cells'])
 else:
  expected=[{'row':r,'column':c,'rowspan':1,'colspan':last-c+1,'text':text} for r,c,last,text in [(0,0,1,'MERGED HEADER'),(0,2,2,'TOTAL'),(1,0,0,'A1'),(1,1,1,'B1'),(1,2,2,'C1'),(2,0,0,'A2'),(2,1,1,'B2'),(2,2,2,'C2')]]
  result['expectedTables']=1
  if len(tables)==1 and 'cells' in tables[0]:result['quality']=measure(expected,tables[0]['cells'])
 overlay.save(str(prefix)+'-overlay.png');signal.alarm(0)
 (OUT/(path.stem+'-result.json')).write_text(json.dumps(result,indent=2,ensure_ascii=False)+'\n');print('CASE',source,json.dumps({k:v for k,v in result.items() if k not in ['tables','detections']}),flush=True);return result
if __name__=='__main__':
 results=[]
 for source in sys.argv[1:]:results.append(run(source))
 print('TOTAL_SECONDS',time.monotonic()-START,flush=True)
