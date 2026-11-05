from pathlib import Path
from PIL import Image,PngImagePlugin
import subprocess,shutil,json,hashlib,os
r=Path(os.environ.get('PMT_PREVIEW_TEST_ROOT',str(Path(__file__).parent)))/'fixtures';r.mkdir(exist_ok=True)
ps='''%!PS
<< /PageSize [400 300] >> setpagedevice
1 0 0 setrgbcolor 0 0 400 300 rectfill
0 0 0 setrgbcolor /Helvetica findfont 30 scalefont setfont 40 160 moveto (PAGE ONE) show showpage
0 0 1 setrgbcolor 0 0 400 300 rectfill
1 1 1 setrgbcolor 40 160 moveto (PAGE TWO) show showpage
'''
(r/'pages.ps').write_text(ps)
subprocess.run(['gs','-q','-sDEVICE=pdfwrite','-dBATCH','-dNOPAUSE','-sOutputFile='+str(r/'pages.pdf'),str(r/'pages.ps')],check=True)
subprocess.run(['qpdf',str(r/'pages.pdf'),'--rotate=+90:2',str(r/'rotated.pdf')],check=True)
image=Image.new('RGBA',(80,40),(255,0,0,0))
for x in range(40,80):
 for y in range(40):image.putpixel((x,y),(0,220,0,255))
meta=PngImagePlugin.PngInfo();meta.add_itxt('XML:com.adobe.xmp','PRIVATE_SYNTHETIC_XMP');image.save(r/'alpha.png',pnginfo=meta)
a=Image.new('RGB',(40,80),'red');exif=Image.Exif();exif[274]=6;a.save(r/'oriented.jpg',exif=exif)
a=Image.new('RGB',(70,40),'red');b=Image.new('RGB',(90,30),'blue');a.save(r/'frames.tiff',save_all=True,append_images=[b]);a.save(r/'frames.gif',save_all=True,append_images=[Image.new('RGB',a.size,'blue')],duration=100,loop=0)
Image.new('RGB',(2500,1500),'green').save(r/'large.png')
(r/'broken.png').write_bytes(b'\x89PNG\r\n\x1a\nBROKEN')
with (r/'over-source.png').open('wb') as f:f.truncate(128*1024*1024+1)
heic=Path(os.environ.get('PMT_HEIC_FIXTURES',str(Path(__file__).parent.parent/'heic-fixtures')))
for p in heic.glob('*.heic'):shutil.copy2(p,r/p.name)
(r/'hashes.json').write_text(json.dumps({p.name:hashlib.file_digest(p.open('rb'),'sha256').hexdigest() for p in r.iterdir() if p.is_file() and p.suffix!='.json'},indent=2))
