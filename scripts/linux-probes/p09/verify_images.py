#!/usr/bin/env python3
"""Echte Raster-/OCR-CLI-Prüfung mit lokal erzeugten Bildframes."""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import zlib

from PIL import Image, ImageDraw, ImageFont

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--cli', required=True, type=Path)
parser.add_argument('--font', required=True, type=Path)
parser.add_argument('--evidence', type=Path)
parser.add_argument('--structured-runtime', choices=['unavailable', 'available'], default='unavailable')
args = parser.parse_args()
cli = args.cli.resolve()
font = ImageFont.truetype(str(args.font), 64)
records = {}


def image(text):
    result = Image.new('RGB', (1500, 450), 'white')
    ImageDraw.Draw(result).text((70, 140), text, fill='black', font=font)
    return result


def run(source, output, extra=()):
    return subprocess.run([str(cli), '--json', '--report', '--source-map', '--ocr-language', 'en',
                           *extra, '--output', str(output), '--', str(source)],
                          capture_output=True, text=True, timeout=150 if "structured" in extra else 45)


with tempfile.TemporaryDirectory(prefix='pmt-p09-images-') as temporary:
    root = Path(temporary)
    first, second = image('FRAMEONETOKEN 1234'), image('FRAMETWOTOKEN 5678')
    for suffix in ['png', 'jpg', 'bmp', 'webp']:
        first.save(root / ('scan.' + suffix))
    first.save(root / 'frames.gif', save_all=True, append_images=[second], duration=100, loop=0)
    first.save(root / 'frames.tiff', save_all=True, append_images=[second])
    first.save(root / 'animated.png', save_all=True, append_images=[second], duration=100, loop=0)
    rotated = first.rotate(90, expand=True)
    exif = rotated.getexif()
    exif[274] = 6
    rotated.save(root / 'rotated.jpg', exif=exif)
    transparent = Image.new('RGBA', first.size, (0, 0, 0, 0))
    ImageDraw.Draw(transparent).text((70, 140), 'FRAMEONETOKEN 1234', fill=(0, 0, 0, 255), font=font)
    transparent.save(root / 'transparent.png')
    sources = sorted(root.iterdir())
    for source in sources:
        before = source.read_bytes()
        output = root / (source.name + '-out')
        response = run(source, output)
        assert response.returncode == 0, (source.name, response.stdout, response.stderr)
        result = json.loads(response.stdout)
        markdown = Path(result['markdownFile']).read_text()
        assets = list((output / 'images').iterdir())
        assert len(assets) == 1 and assets[0].read_bytes() == before
        assert source.read_bytes() == before
        assert 'FRAMEONETOKEN' in markdown and '1234' in markdown
        frames = 2 if source.name in ['frames.gif', 'frames.tiff', 'animated.png'] else 1
        if frames == 2:
            assert 'FRAMETWOTOKEN' in markdown and '5678' in markdown
        assert len(result['sourceMappings']) == frames
        assert result['sourceIdentity']['sha256'] == hashlib.sha256(before).hexdigest()
        assert not any(d['code'] == 'ocr.backendFailure' for d in result.get('diagnostics', []))
        for entry in result['outputFiles']:
            assert hashlib.sha256((output / entry['path']).read_bytes()).hexdigest() == entry['sha256']
        records[source.name] = {'passed': True, 'frames': frames, 'sourceAndAssetBytesUnchanged': True,
                                'reportAndOutputHashes': True, 'OCRMarkers': True}
    source = root / 'scan.png'
    response = run(source, root / 'no-ocr', ['--image-ocr', 'off'])
    assert response.returncode == 0
    assert '## OCR text' not in Path(json.loads(response.stdout)['markdownFile']).read_text()
    records['image-ocr-off'] = {'passed': True}
    response = run(source, root / 'structured', ['--ocr-method', 'structured'])
    if args.structured_runtime == 'unavailable':
        assert response.returncode == 69 and not (root / 'structured').exists(), response.stdout
        records['structured-unavailable'] = {'passed': True, 'exit': 69}
    else:
        assert response.returncode == 0, (response.stdout, response.stderr)
        result = json.loads(response.stdout)
        markdown = Path(result['markdownFile']).read_text()
        assert 'FRAMEONETOKEN 1234' in markdown, markdown
        assert any(d['code'] == 'ocr.structuredApplied' for d in result['diagnostics'])
        assert result['sourceIdentity']['sha256'] == hashlib.sha256(source.read_bytes()).hexdigest()
        assert any(Path(p).read_bytes() == source.read_bytes() for p in result['assets'])
        for entry in result['outputFiles']:
            assert hashlib.sha256((root / 'structured' / entry['path']).read_bytes()).hexdigest() == entry['sha256']
        records['structured-available'] = {'passed': True, 'exit': 0, 'exactOCRText': True,
                                           'sourceAndAssetBytesUnchanged': True, 'reportAndOutputHashes': True}
    response = run(source, root / 'missing-language', ['--ocr-language', 'zzz'])
    assert response.returncode != 0 and not (root / 'missing-language').exists()
    records['missing-language'] = {'passed': True}
    response = run(source, root / 'timeout', ['--image-ocr', 'off', '--timeout', '0.001'])
    assert response.returncode == 124 and not (root / 'timeout').exists(), response.stdout
    records['raster-process-timeout'] = {'passed': True, 'exit': 124, 'noOutput': True}
    payload = b'IHDR' + struct.pack('!IIBBBBB', 100000, 100000, 8, 2, 0, 0, 0)
    oversized = b'\x89PNG\r\n\x1a\n' + struct.pack('!I', len(payload) - 4) + payload + struct.pack('!I', zlib.crc32(payload))
    for name, data in [('oversized.png', oversized), ('truncated.png', source.read_bytes()[:30])]:
        fixture = root / name
        fixture.write_bytes(data)
        response = run(fixture, root / (name + '-out'))
        assert response.returncode == 65 and not (root / (name + '-out')).exists(), response.stdout
        assert fixture.read_bytes() == data
        records[name] = {'passed': True, 'exit': 65, 'noOutput': True}
if args.evidence:
    args.evidence.write_text(json.dumps(records, indent=2) + '\n')
print(f'Raster/OCR: {len(records)} real CLI cases PASS; own temporary fixtures removed.')
