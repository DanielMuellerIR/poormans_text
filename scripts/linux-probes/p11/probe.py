"""Begrenzte klassische Qualitätsvorprobe, kein Produktadapter."""
from pathlib import Path
from PIL import Image, ImageDraw
import argparse, csv, hashlib, io, json, re, subprocess, time
import numpy as np

parser=argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', required=True, type=Path)
ROOT=parser.parse_args().root.resolve()
SOURCE=ROOT/'fixtures/structured.png'
START=time.monotonic()

def groups(values):
    result=[]
    for value in values:
        value=int(value)
        if not result or value>result[-1][-1]+1:result.append([value])
        else:result[-1].append(value)
    return [int(round(sum(group)/len(group))) for group in result]

def geometry(path):
    image=Image.open(path).convert('L');mask=np.asarray(image)<120
    rows=groups(np.flatnonzero(mask.sum(axis=1)>image.width*.65))
    if len(rows)<2:return {'rows':rows,'columns':[],'cells':[]}
    columns=groups(np.flatnonzero(mask[rows[0]:rows[-1]+1].sum(axis=0)>(rows[-1]-rows[0])*.55))
    cells=[]
    for row,(top,bottom) in enumerate(zip(rows,rows[1:])):
        column=0
        while column<len(columns)-1:
            last=column
            while last<len(columns)-2:
                x=columns[last+1]
                boundary=mask[top+6:bottom-6,max(0,x-1):x+2].any(axis=1).mean()
                if boundary>.8:break
                last+=1
            cells.append({'row':row,'firstColumn':column,'lastColumn':last,'box':[columns[column],top,columns[last+1],bottom]})
            column=last+1
    return {'rows':rows,'columns':columns,'cells':cells}

def ocr(path,psm):
    process=subprocess.run(['/usr/bin/tesseract',str(path),'stdout','-l','eng+deu','--psm',str(psm),'tsv'],capture_output=True,text=True,timeout=30)
    assert process.returncode==0,process.stderr
    words=[record for record in csv.DictReader(io.StringIO(process.stdout),delimiter='\t') if record['level']=='5' and record['text'].strip()]
    return words

expected=[(0,0,1,'MERGED HEADER'),(0,2,2,'TOTAL'),(1,0,0,'A1'),(1,1,1,'B1'),(1,2,2,'C1'),(2,0,0,'A2'),(2,1,1,'B2'),(2,2,2,'C2')]
base=Image.open(SOURCE).convert('RGB')
variants={'original':SOURCE}
base.rotate(2,resample=Image.Resampling.BICUBIC,fillcolor='white').save(ROOT/'fixtures/rotated.png');variants['rotated']=ROOT/'fixtures/rotated.png'
borderless=base.copy();draw=ImageDraw.Draw(borderless)
for y in [600,740,880,1020]:draw.line((65,y,1575,y),fill='white',width=9)
for x in [70,570,1070,1570]:draw.line((x,735 if x==570 else 595,x,1025),fill='white',width=9)
borderless.save(ROOT/'fixtures/borderless.png');variants['borderless']=ROOT/'fixtures/borderless.png'
results={}
for name,path in variants.items():
    shape=geometry(path);results[name]={'geometry':shape,'geometryMatch':[(c['row'],c['firstColumn'],c['lastColumn']) for c in shape['cells']]==[cell[:3] for cell in expected]}
    if name=='original':
        strings=[]
        for index,cell in enumerate(shape['cells']):
            x0,y0,x1,y1=cell['box'];crop=base.crop((x0+10,y0+10,x1-10,y1-10));target=ROOT/'outputs'/f'cell-{index}.png';crop.save(target)
            words=ocr(target,6);text=' '.join(word['text'] for word in words);strings.append(text);cell['text']=text
        results[name]['exactCellMatches']=sum(got==wanted[3] for got,wanted in zip(strings,expected))
        results[name]['expectedCellCount']=len(expected)
        results[name]['cellStrings']=strings
        whole=ocr(path,3)
        # Nur eine obere Zweispaltenregion: bewusste manuelle Bereichsvorgabe,
        # keine behauptete allgemeine Seitensegmentierung.
        region=[word for word in whole if 150<int(word['top'])<320]
        results[name]['originalColumnWords']=[word['text'] for word in region]
        columns=[]
        for left,right in [(0,900),(900,1800)]:
            words=sorted([word for word in region if left<=int(word['left'])<right],key=lambda word:(round(int(word['top'])/20),int(word['left'])))
            columns.append(' '.join(word['text'] for word in words))
        results[name]['manuallySeparatedColumns']=columns
        results[name]['manualColumnMarkerOrder']=re.findall(r'ALPHA|BETA|GAMMA|DELTA',' '.join(columns))
# Ein vorhandenes klassisches Deskew-Werkzeug fair gegen den Rotationsfall prüfen.
process=subprocess.run(['/usr/bin/magick',str(variants['rotated']),'-deskew','40%',str(ROOT/'fixtures/deskewed.png')],capture_output=True,text=True,timeout=30)
if process.returncode==0:results['deskewed']={'geometry':geometry(ROOT/'fixtures/deskewed.png')}
else:results['deskewed']={'error':process.stderr[:1000]}
summary={'sourceSha256':hashlib.sha256(SOURCE.read_bytes()).hexdigest(),'sourceGenerator':'scripts/linux-probes/backends/extra-probe.py (unmodified structured-raster prefix)','expectedCells':[{'row':r,'firstColumn':c,'lastColumn':last,'text':text} for r,c,last,text in expected],'results':results,'wallSeconds':time.monotonic()-START,'pairedRawMacOutputAvailable':False,'naturalGroundTruthTested':False,'P11Passed':False}
(ROOT/'results.json').write_text(json.dumps(summary,indent=2));print(json.dumps(summary,indent=2))
