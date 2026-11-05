import resource
resource.setrlimit(resource.RLIMIT_AS, (1536 * 1024 * 1024,) * 2)
resource.setrlimit(resource.RLIMIT_FSIZE, (300 * 1024 * 1024,) * 2)
import hashlib, json, pathlib, sys
import argparse, importlib.util
parser = argparse.ArgumentParser()
parser.add_argument('--helper', type=pathlib.Path, required=True)
parser.add_argument('--fixtures', type=pathlib.Path, required=True)
args = parser.parse_args()
specification = importlib.util.spec_from_file_location('pmt_heif', args.helper)
module = importlib.util.module_from_spec(specification)
specification.loader.exec_module(module)
Decoder = module.Decoder
root = args.fixtures
results = []
for name in ['single', 'rotated', 'multi']:
    source = root / (name + '.heic')
    before = hashlib.sha256(source.read_bytes()).hexdigest()
    decoder = Decoder()
    try:
        frames = []
        for index, (meta, image) in enumerate(decoder.frames(source, True)):
            image.save(root / (name + f'-{index + 1}.png'))
            frames.append(meta)
            assert image.getchannel('A').getextrema() == (0, 255)
        results.append({'source': name, 'frames': frames, 'sourceUnchanged': before == hashlib.sha256(source.read_bytes()).hexdigest()})
    finally:
        decoder.close()
assert results[0]['frames'][0]['width'] == 32
assert (results[1]['frames'][0]['width'], results[1]['frames'][0]['height']) == (24, 32)
assert len(results[2]['frames']) == 2
(root / 'broken.heic').write_bytes((root / 'single.heic').read_bytes()[:96])
decoder = Decoder()
try:
    try:
        list(decoder.frames(root / 'broken.heic', False))
    except ValueError:
        results.append({'brokenRejected': True})
    else:
        raise AssertionError('broken accepted')
finally:
    decoder.close()
print(json.dumps(results, indent=2))
