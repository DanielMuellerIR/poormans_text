#!/usr/bin/env python3
"""Begrenzter Poppler-/Tesseract-DPIvergleich ohne Produktänderung oder GT-Tuning."""
import argparse,collections,csv,hashlib,importlib.util,io,json,math,re,subprocess,time
from pathlib import Path
import gi,cairo
gi.require_version('Poppler','0.18');from gi.repository import Poppler
p=argparse.ArgumentParser();p.add_argument('--repo',type=Path,required=True);p.add_argument('--synthetic',type=Path,required=True);p.add_argument('--root',type=Path,required=True);a=p.parse_args();a.root.mkdir(exist_ok=False)
spec=importlib.util.spec_from_file_location('natural',a.repo/'scripts/linux-probes/p11/natural_benchmark.py');natural=importlib.util.module_from_spec(spec);spec.loader.exec_module(natural)
gt=json.loads((a.repo/'docs/linux-port/P11-NATURAL-EVIDENCE/selected-reference.json').read_text());cases=[]
for name,record in gt.items():
 texts=[]
 for element in record['elements']:
  if element['category']=='Table':parser=natural.HTML();parser.feed(element['content']['html']);texts.append(' '.join(parser.text))
  else:texts.append(element['content']['text'])
 cases.append((name,a.repo/'docs/linux-port/P11-NATURAL-EVIDENCE/inputs'/name,' '.join(texts),'eng'))
synthetic='DIGITAL HEADER 98765\n'+'\n'.join(['Invoice ALPHA 12345','Die Rechnung kostet 42 Euro.','Grüße aus München und schöne Grüße.','The quick brown fox jumps over the lazy dog.']+['Rotation sentinel ALPHA 12345']*5)
cases.append(('mixed-synthetic',a.synthetic,synthetic,'deu+eng'))
langs=subprocess.run(['tesseract','--list-langs'],capture_output=True,text=True,check=True).stdout
psm='1' if 'osd' in langs.split() else '3';records=[]
for name,source,expected,languages in cases:
 doc=Poppler.Document.new_from_file(source.resolve().as_uri(),None);page=doc.get_page(0);width,height=page.get_size()
 for dpi in (144,300):
  scale=min(dpi/72,math.sqrt(16_000_000/(width*height)),16384/max(width,height));w,h=max(1,int(width*scale)),max(1,int(height*scale));prefix=a.root/(name+'-'+str(dpi));png=prefix.with_suffix('.png')
  surface=cairo.ImageSurface(cairo.FORMAT_RGB24,w,h);context=cairo.Context(surface);context.set_source_rgb(1,1,1);context.paint();context.scale(w/width,h/height)
  if hasattr(page,'render_full'):page.render_full(context,True,Poppler.RenderAnnotsFlags(0))
  else:page.render_for_printing_with_options(context,Poppler.PrintFlags.DOCUMENT)
  surface.write_to_png(str(png));surface.finish();started=time.monotonic()
  cmd=['tesseract',str(png),'stdout','-l',languages,'--psm',psm,'tsv'];r=subprocess.run(cmd,capture_output=True,text=True,timeout=60);prefix.with_suffix('.tsv').write_text(r.stdout);prefix.with_suffix('.stderr').write_text(r.stderr)
  words=[row['text'] for row in csv.DictReader(io.StringIO(r.stdout),delimiter='\t') if row.get('level')=='5' and row.get('text','').strip()];text=' '.join(words);prefix.with_suffix('.txt').write_text(text+'\n');diff=natural.diff(expected,text)
  records.append({'source':name,'requestedDPI':dpi,'effectiveDPI':scale*72,'width':w,'height':h,'pixels':w*h,'pagesWithin64MP':64_000_000//(w*h),'pageCount':doc.get_n_pages(),'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'rasterSHA256':hashlib.sha256(png.read_bytes()).hexdigest(),'command':cmd,'exit':r.returncode,'seconds':round(time.monotonic()-started,3),'wordInventory':diff})
  png.unlink()
summary={'purpose':'raw OCR only; not product digital/OCR merge; no GT substitutions, no tuning','installedLanguages':langs,'psm':psm,'tesseractVersion':subprocess.run(['tesseract','--version'],capture_output=True,text=True).stdout.splitlines()[0],'cases':records}
(a.root/'summary.json').write_text(json.dumps(summary,ensure_ascii=False,indent=2)+'\n')
print(json.dumps([{k:c[k] for k in ['source','requestedDPI','effectiveDPI','pixels','pagesWithin64MP','exit']}|{'expected':c['wordInventory']['expected'],'actual':c['wordInventory']['actual'],'matched':c['wordInventory']['matched'],'missing':sum(c['wordInventory']['missing'].values()),'extra':sum(c['wordInventory']['extra'].values())} for c in records],indent=2))
raise SystemExit(any(c['exit'] for c in records))
