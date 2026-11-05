"""Benigner AutoOpen-Quellträger aus dem exakt gehashten öffentlichen POI-Fixture.
Der ursprüngliche TestMacro-P-Code bleibt absichtlich unverändert; geprüft wird
LibreOffices tatsächlich beobachtete VBA-Quelltextausführung, keine Word-Parität.
"""
import pathlib, shutil, hashlib, json
import olefile
from oletools.olevba import VBA_Project, decompress_stream
import argparse
parser = argparse.ArgumentParser()
parser.add_argument('original', type=pathlib.Path)
parser.add_argument('target', type=pathlib.Path)
args = parser.parse_args()
original = args.original
target = args.target
assert hashlib.sha256(original.read_bytes()).hexdigest() == '39e9608c711d38f298ed20a5bfae12fcdaed6f4be2be4d26db670475216ca393'
with target.open('xb') as output:
    output.write(original.read_bytes())
o = olefile.OleFileIO(target, write_mode=True)
project = VBA_Project(o, 'Macros/', 'Macros/PROJECT', 'Macros/VBA/dir')
list(project.parse_modules())
module = next((m for m in project.modules if m.name == 'Module1'))
stream = o.openstream(module.code_path).read()
space = len(stream) - module.textoffset
source = b'Attribute VB_Name = "Module1"\r\nPublic Sub AutoOpen()\r\nOpen "/pmt/work-scope/m.sentinel" For Output As #1:Print #1,1:Close #1\r\nEnd Sub\r\n'
source += b"'" + b' ' * (156 - len(source) - 1)
assert len(source) == 156
payload = b''.join((b'\x00' + source[n:n + 8] for n in range(0, len(source), 8)))
compressed = b'\x01' + (45056 | len(payload) - 1).to_bytes(2, 'little') + payload
assert len(compressed) == space, (len(compressed), space)
assert decompress_stream(compressed) == source
o.write_stream(module.code_path, stream[:module.textoffset] + compressed)
o.close()
print(json.dumps({'originalSHA256': hashlib.sha256(original.read_bytes()).hexdigest(), 'modifiedSHA256': hashlib.sha256(target.read_bytes()).hexdigest(), 'module': module.code_path, 'moduleOffset': module.textoffset, 'compressedBytes': space, 'source': source.decode()}))
