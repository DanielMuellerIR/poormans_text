from pathlib import Path
import json, hashlib, subprocess, sys
root = Path(sys.argv[1])
cli = Path(sys.argv[3]) if len(sys.argv) > 3 else root / 'poormans-text'
results = []
output_root = Path(sys.argv[2]) if len(sys.argv) > 2 else root / 'results'
output_root.mkdir(parents=True, exist_ok=True)

def run(name, args, expected=0):
    p = subprocess.run([str(cli), '--json', *args], capture_output=True, timeout=40)
    v = json.loads(p.stdout)
    assert p.returncode == expected, (name, p.returncode, v, p.stderr)
    results.append({'case': name, 'exit': p.returncode, 'response': v})
    return v
catalog = run('catalog', ['--formats'])
image_rows = [f for f in catalog['formats'] if f['format'] == 'image']
assert len(image_rows) == 1
image = image_rows[0]
assert image['available'] and 'png' in image['extensions']
has = 'heic' in image['extensions']
for name in ['single', 'rotated', 'multi']:
    source = root / 'fixtures' / (name + '.heic')
    original = hashlib.sha256(source.read_bytes()).hexdigest()
    for ocr in ['off', 'on']:
        output = output_root / (name + '-' + ocr)
        v = run(name + '-' + ocr, ['--image-ocr', ocr, '--output', str(output), '--', str(source)], 0 if has else 69)
        if not has:
            assert not output.exists()
            continue
        assert any((d['code'] == 'image.heicRender' for d in v['diagnostics']))
        assert not any((d['code'] == 'ocr.backendFailure' for d in v['diagnostics']))
        markdown = Path(v['markdownFile']).read_text()
        assert '[Original HEIC]' in markdown and 'images/frame-1.png' in markdown
        assert ('## OCR text' in markdown) == (ocr == 'on')
        assets = [Path(a) for a in v['assets']]
        raw = next((a for a in assets if a.suffix == '.heic'))
        assert hashlib.sha256(raw.read_bytes()).hexdigest() == original
        assert hashlib.sha256(source.read_bytes()).hexdigest() == original
        assert len([a for a in assets if a.suffix == '.png']) == (2 if name == 'multi' else 1)
for name in ['broken', 'oversize', 'too-many']:
    if has:
        run(name, ['--output', str(output_root / name), '--', str(root / 'fixtures' / (name + '.heic'))], 65)
(output_root / 'receipts.json').write_text(json.dumps(results, ensure_ascii=False, indent=2))
print(json.dumps({'cases': len(results), 'heicAdvertised': has, 'pngAvailable': image['available']}))
