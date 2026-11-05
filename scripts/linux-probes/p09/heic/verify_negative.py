import resource
resource.setrlimit(resource.RLIMIT_AS, (1536 * 1024 * 1024,) * 2)
import hashlib, json, pathlib
from PIL import Image
import argparse, importlib.util
parser = argparse.ArgumentParser()
parser.add_argument('--helper', type=pathlib.Path, required=True)
parser.add_argument('--fixtures', type=pathlib.Path, required=True)
args = parser.parse_args()
specification = importlib.util.spec_from_file_location('pmt_heif', args.helper)
module = importlib.util.module_from_spec(specification)
specification.loader.exec_module(module)
Decoder = module.Decoder
r = args.fixtures
data = bytearray((r / 'single.heic').read_bytes())
pos = data.index(b'ispe')
data[pos + 8:pos + 12] = 1000000 .to_bytes(4, 'big')
(r / 'oversize.heic').write_bytes(data)
records = []
for name in ['broken', 'oversize', 'too-many']:
    decoder = Decoder()
    called = [0]
    original = decoder.library.heif_decode_image

    def decode(*args):
        called[0] += 1
        return original(*args)
    decoder.library.heif_decode_image = decode
    try:
        try:
            list(decoder.frames(r / (name + '.heic'), False))
        except ValueError as e:
            records.append({'case': name, 'rejected': True, 'decodeCalls': called[0], 'reason': str(e)})
        else:
            raise AssertionError(name + ' accepted')
    finally:
        decoder.close()
    assert called[0] == 0
for name, n in [('single', 0), ('rotated', 0), ('multi', 1)]:
    w = 40 if n else 32
    expected = Image.new('RGBA', (w, 24))
    expected.putdata([(x * 7 % 256, y * 9 % 256, n * 70 % 256, 0 if x < 8 else 255) for y in range(24) for x in range(w)])
    if name == 'rotated':
        expected = expected.transpose(Image.Transpose.ROTATE_270)
    actual = Image.open(r / (name + ('-2.png' if n else '-1.png'))).convert('RGBA')
    assert actual.size == expected.size
    errors = [abs(a - b) for p, q in zip(actual.getdata(), expected.getdata()) if q[3] for a, b in zip(p[:3], q[:3])]
    assert max(errors) <= 2, (name, max(errors))
    assert list(actual.getchannel('A').getdata()) == list(expected.getchannel('A').getdata())
    records.append({'case': name, 'maxRGBError': max(errors), 'alphaAndOrientation': True})
print(json.dumps(records, indent=2))
