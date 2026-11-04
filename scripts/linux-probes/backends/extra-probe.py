from pathlib import Path
from PIL import Image,ImageDraw,ImageFont
import subprocess,json,zlib,hashlib,os,sys
r=Path(os.environ.get('PMT_P04_ROOT', sys.argv[1] if len(sys.argv)>1 else '/tmp/pmt-p04'));f=r/'fixtures';o=r/'outputs';font=ImageFont.truetype(os.environ.get('PMT_P04_FONT','/usr/share/fonts/TTF/DejaVuSans.ttf'),38)
p=Image.new('RGB',(1800,1600),'white');d=ImageDraw.Draw(p)
for xy,s in [((70,60),'STRUCTURED DOCUMENT'),((70,170),'LEFT ALPHA paragraph'),((70,240),'LEFT BETA paragraph'),((950,170),'RIGHT GAMMA paragraph'),((950,240),'RIGHT DELTA paragraph'),((70,370),'1. First list item'),((70,440),'2. Second list item')]:d.text(xy,s,fill='black',font=font)
for y in [600,740,880,1020]:d.line((70,y,1570,y),fill='black',width=3)
for x in [70,570,1070,1570]:d.line((x,740 if x==570 else 600,x,1020),fill='black',width=3)
for xy,s in [((100,640),'MERGED HEADER'),((1100,640),'TOTAL'),((100,780),'A1'),((600,780),'B1'),((1100,780),'C1'),((100,920),'A2'),((600,920),'B2'),((1100,920),'C2')]:d.text(xy,s,fill='black',font=font)
for x in range(300):
 for y in range(200):p.putpixel((100+x,1150+y),(x%256,y%256,(x+y)%256))
p.save(f/'structured.png',dpi=(300,300))
res={}
a=['/usr/bin/tesseract',str(f/'structured.png'),str(o/'structured'),'-l','eng+deu','--psm','3','txt','hocr','tsv'];q=subprocess.run(a,capture_output=True,text=True,timeout=30);res['structured']=dict(exit=q.returncode,stderr=q.stderr,text=(o/'structured.txt').read_text(),semantic_table_tags=any(k in (o/'structured.hocr').read_text() for k in ['ocr_table','ocr_cell','<table']))
im=Image.open(f/'ocr.png').convert('RGB');w,h=im.size
objs=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {w} {h+100}] /Resources << /Font << /F1 4 0 R >> /XObject << /Im1 6 0 R >> >> /Contents 5 0 R >>'.encode(),b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
def stream(data,attrs=b''):return b'<< /Length '+str(len(data)).encode()+b' '+attrs+b' >>\nstream\n'+data+b'\nendstream'
objs += [stream(f'BT /F1 42 Tf 80 {h+30} Td (DIGITAL HEADER 98765) Tj ET q {w} 0 0 {h} 0 0 cm /Im1 Do Q'.encode()),stream(zlib.compress(im.tobytes()),f'/Type /XObject /Subtype /Image /Width {w} /Height {h} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode'.encode())]
data=b'%PDF-1.4\n';off=[0]
for i,obj in enumerate(objs,1):off.append(len(data));data+=f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n'
x=len(data);data+=f'xref\n0 {len(objs)+1}\n0000000000 65535 f \n'.encode()+b''.join(f'{a:010d} 00000 n \n'.encode() for a in off[1:])+f'trailer << /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n'.encode();(f/'mixed.pdf').write_bytes(data)
q=subprocess.run(['/usr/bin/pdftotext',str(f/'mixed.pdf'),'-'],capture_output=True,text=True,timeout=10);res['mixed_digital']=q.stdout
q=subprocess.run(['/usr/bin/pdftoppm','-scale-to','2000','-png','-singlefile',str(f/'mixed.pdf'),str(o/'mixed-render')],capture_output=True,text=True,timeout=15);res['mixed_render']=dict(exit=q.returncode,stderr=q.stderr)
q=subprocess.run(['/usr/bin/tesseract',str(o/'mixed-render.png'),str(o/'mixed-ocr'),'-l','eng+deu','--psm','3','txt','tsv'],capture_output=True,text=True,timeout=30);res['mixed_ocr']=dict(exit=q.returncode,stderr=q.stderr,text=(o/'mixed-ocr.txt').read_text())
(o/'extra-results.json').write_text(json.dumps(res,indent=2,ensure_ascii=False));print(json.dumps(res,indent=2,ensure_ascii=False))
