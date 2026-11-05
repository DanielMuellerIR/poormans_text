from pathlib import Path
from PIL import Image
import zlib
image=Image.open('/work/source.png').convert('RGB');data=zlib.compress(image.tobytes());stream=b'q 864 0 0 768 0 40 cm /Im0 Do Q\nBT /F1 10 Tf 40 15 Td (DIGITAL ORIGINAL MUST SURVIVE 7319) Tj ET\n'
objects=[b'<< /Type /Catalog /Pages 2 0 R >>',b'<< /Type /Pages /Count 1 /Kids [3 0 R] >>',b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 864 808] /Resources << /XObject << /Im0 4 0 R >> /Font << /F1 6 0 R >> >> /Contents 5 0 R >>',f'<< /Type /XObject /Subtype /Image /Width {image.width} /Height {image.height} /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /FlateDecode /Length {len(data)} >>\nstream\n'.encode()+data+b'\nendstream',f'<< /Length {len(stream)} >>\nstream\n'.encode()+stream+b'endstream',b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
out=bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n');offsets=[0]
for i,obj in enumerate(objects,1):offsets.append(len(out));out+=f'{i} 0 obj\n'.encode()+obj+b'\nendobj\n'
xref=len(out);out+=f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode()
for n in offsets[1:]:out+=f'{n:010d} 00000 n \n'.encode()
out+=f'trailer\n<< /Size {len(offsets)} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode();Path('/work/mixed.pdf').write_bytes(out)
