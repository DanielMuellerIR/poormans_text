from pathlib import Path
from PIL import Image, ImageDraw, ImageFont, ImageOps
import json, subprocess, time, hashlib, struct, zlib, resource, os, sys
import gi
gi.require_version('Poppler','0.18')
from gi.repository import Poppler, GLib
ROOT=Path(os.environ.get('PMT_P04_ROOT', sys.argv[1] if len(sys.argv)>1 else '/tmp/pmt-p04')); (ROOT/'fixtures').mkdir(exist_ok=True); (ROOT/'outputs').mkdir(exist_ok=True)
F=ROOT/'fixtures'; O=ROOT/'outputs'; results={}
def run(args):
 t=time.monotonic(); p=subprocess.run(args,capture_output=True,text=True,timeout=30); return dict(exit=p.returncode,stdout=p.stdout[:20000],stderr=p.stderr[:4000],seconds=round(time.monotonic()-t,3))
def pdf(path):
 objs=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Kids [3 0 R 8 0 R] /Count 2 >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 4 0 R >> /XObject << /Im1 6 0 R >> >> /Contents 5 0 R /Annots [7 0 R 10 0 R] >>',b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
 def stream(data,attrs=b''):return b'<< /Length '+str(len(data)).encode()+b' '+attrs+b' >>\nstream\n'+data+b'\nendstream'
 objs += [stream(b'BT /F1 20 Tf 40 740 Td (ALPHA left column) Tj 300 0 Td (BETA right) Tj -300 -40 Td (GAMMA next line) Tj ET q 40 0 0 30 40 620 cm /Im1 Do Q'),stream(bytes([255,0,0,0,255,0,0,0,255,255,255,0]),b'/Type /XObject /Subtype /Image /Width 2 /Height 2 /ColorSpace /DeviceRGB /BitsPerComponent 8'),b'<< /Type /Annot /Subtype /Link /Rect [40 730 220 760] /A << /S /URI /URI (https://example.invalid/pmt-never-fetch) >> >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 600 800] /Resources << /Font << /F1 4 0 R >> >> /Contents 9 0 R >>',stream(b'BT /F1 20 Tf 40 740 Td (DELTA page two) Tj ET'),b'<< /Type /Annot /Subtype /Text /Rect [300 600 325 625] /Contents (NOTE annotation sentinel) /T (Fixture author) >>']
 data=b'%PDF-1.4\n'; offsets=[0]
 for i,obj in enumerate(objs,1):offsets.append(len(data)); data+=f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n'
 x=len(data);data+=f'xref\n0 {len(objs)+1}\n0000000000 65535 f \n'.encode()+b''.join(f'{a:010d} 00000 n \n'.encode() for a in offsets[1:])+f'trailer << /Size {len(objs)+1} /Root 1 0 R >>\nstartxref\n{x}\n%%EOF\n'.encode();path.write_bytes(data)
pdf(F/'sample.pdf'); (F/'broken.pdf').write_bytes(b'%PDF-1.4\nnot a document')
doc=Poppler.Document.new_from_file((F/'sample.pdf').as_uri(),None); pages=[]
for i in range(doc.get_n_pages()):
 p=doc.get_page(i); ok,boxes=p.get_text_layout(); links=p.get_link_mapping(); annots=p.get_annot_mapping(); images=p.get_image_mapping()
 pages.append(dict(text=p.get_text(),size=p.get_size(),layout_count=len(boxes),layout_ok=ok,first_box=([boxes[0].x1,boxes[0].y1,boxes[0].x2,boxes[0].y2] if boxes else None),images=[dict(id=x.image_id,area=[x.area.x1,x.area.y1,x.area.x2,x.area.y2],size=[p.get_image(x.image_id).get_width(),p.get_image(x.image_id).get_height()]) for x in images],link_count=len(links),annotations=[dict(type=str(x.annot.get_annot_type()),contents=x.annot.get_contents()) for x in annots]))
try: Poppler.Document.new_from_file((F/'broken.pdf').as_uri(),None); broken='UNEXPECTED success'
except GLib.Error as e: broken=str(e)
results['pdf']=dict(pages=pages,broken=broken,bbox=run(['/usr/bin/pdftotext','-bbox',str(F/'sample.pdf'),str(O/'pdf-bbox.html')]),images=run(['/usr/bin/pdfimages','-png',str(F/'sample.pdf'),str(O/'pdfimage')]))
font=ImageFont.truetype(os.environ.get('PMT_P04_FONT','/usr/share/fonts/TTF/DejaVuSans.ttf'),42)
page=Image.new('RGB',(1600,1100),'white'); draw=ImageDraw.Draw(page)
lines=['Invoice ALPHA 12345','Die Rechnung kostet 42 Euro.','Grüße aus München und schöne Grüße.','The quick brown fox jumps over the lazy dog.']
for i,line in enumerate(lines):draw.text((80,80+i*100),line,font=font,fill='black')
for i in range(5):draw.text((80,550+i*80),'Rotation sentinel ALPHA 12345',font=font,fill='black')
page.save(F/'ocr.png',dpi=(300,300));page.rotate(90,expand=True).save(F/'ocr-rotated.png',dpi=(300,300))
ocr={}
for name,psm in [('ocr',3),('ocr-rotated',1)]:
 base=O/name; outcome=run(['tesseract',str(F/(name+'.png')),str(base),'-l','eng+deu','--psm',str(psm),'txt','tsv','hocr']);txt=base.with_suffix('.txt').read_text();ocr[name]=dict(process=outcome,text=txt,alpha_count=txt.count('ALPHA'),german_preserved='Grüße aus München' in txt,tsv_word_rows=sum(1 for l in base.with_suffix('.tsv').read_text().splitlines()[1:] if l.split('\t')[0]=='5'),hocr_has_bbox='bbox ' in base.with_suffix('.hocr').read_text())
ocr['missing_language']=run(['tesseract',str(F/'ocr.png'),str(O/'missing'),'-l','zzz'])
results['ocr']=ocr
base=Image.new('RGB',(80,40),'red');base.save(F/'basic.png');base.save(F/'basic.webp');base.save(F/'basic.bmp');exif=Image.Exif();exif[274]=6;base.save(F/'oriented.jpg',exif=exif)
base.save(F/'frames.gif',save_all=True,append_images=[Image.new('RGB',(80,40),'blue')],duration=100,loop=0)
base.save(F/'frames.tiff',save_all=True,append_images=[Image.new('RGB',(80,40),'blue')])
(F/'broken.png').write_bytes(b'\x89PNG\r\n\x1a\ncorrupt')
def chunk(t,b):return struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)
(F/'huge.png').write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',100000,100000,8,2,0,0,0))+chunk(b'IEND',b''))
images={}
for path in [F/n for n in ['basic.png','basic.webp','basic.bmp','oriented.jpg','frames.gif','frames.tiff','broken.png','huge.png']]:
 try:
  with Image.open(path) as im:
   info=dict(size=im.size,format=im.format,frames=getattr(im,'n_frames',1),orientation=im.getexif().get(274));
   if path.name=='oriented.jpg': info['oriented_size']=ImageOps.exif_transpose(im).size

   with Image.open(path) as fresh: fresh.verify()
   info['verify']='success'
   with Image.open(path) as decoded:
    info['frame_pixels']=[]
    for frame in range(getattr(decoded,'n_frames',1)):
     decoded.seek(frame);decoded.load();info['frame_pixels'].append(decoded.convert('RGB').getpixel((0,0)))
 except Exception as e:info=dict(error=type(e).__name__+': '+str(e))
 images[path.name]=info
(F/'basic.heic').unlink(missing_ok=True)
images['heic_write']=run(['/usr/bin/magick',str(F/'basic.png'),'HEIC:'+str(F/'basic.heic')]);images['heic_identify']=run(['/usr/bin/magick','identify','-ping','-format','%m %w %h %n',str(F/'basic.heic')]); results['images']=images

if __import__('shutil').which('qpdf'):
 results['pdf']['encrypt_fixture']=run(['qpdf','--encrypt','fixture','fixture','256','--',str(F/'sample.pdf'),str(F/'encrypted.pdf')])
 results['pdf']['encrypted_error']=run(['/usr/bin/pdftotext',str(F/'encrypted.pdf'),str(O/'encrypted.txt')])
results['source_hashes']={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in F.iterdir() if p.is_file()}
(O/'results.json').write_text(json.dumps(results,indent=2,ensure_ascii=False));print(json.dumps(results,indent=2,ensure_ascii=False))
