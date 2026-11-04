"""Dieselben selbst erzeugten Fixtures auf einem nativen Mac prüfen."""
from pathlib import Path
import subprocess, json, time, sys
root=Path(sys.argv[1]).resolve()
cli=Path(sys.argv[2]).resolve()
out=root/'mac-output';out.mkdir(exist_ok=False)
cases=[(n,[],n) for n in ['sample.pdf','broken.pdf','encoded.rtf','encoded.doc','local.rtfd','ocr.png','ocr-rotated.png','oriented.jpg','frames.gif','frames.tiff']]
cases += [('structured.png',['--ocr-method','structured'],'structured'),('mixed.pdf',[],'mixed'),('sample.pdf',['--pdf-ocr','off'],'pdf-off')]
results={}
for name,options,label in cases:
    source=root/'fixtures'/name
    if name=='encoded.doc' and not source.exists(): source=root/'outputs/doc/encoded.doc'
    start=time.monotonic()
    try:
        p=subprocess.run([str(cli),'--json','--report','--ocr-language','de,en','--output',str(out/label)]+options+[str(source)],capture_output=True,text=True,timeout=90)
        results[label]=dict(exit=p.returncode,stdout=p.stdout,stderr=p.stderr,seconds=round(time.monotonic()-start,3))
    except subprocess.TimeoutExpired:
        results[label]=dict(timeout=True)
(out/'results.json').write_text(json.dumps(results,indent=2,ensure_ascii=False))
