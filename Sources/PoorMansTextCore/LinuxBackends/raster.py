"""Begrenzter Rasterdecoder; nur aus dem isolierten PMT-Prozessadapter aufrufen."""
import argparse
import errno
import json
import math
import os
from pathlib import Path
import resource
import sys
import warnings
import importlib.util
import importlib.machinery
from contextlib import closing

# Vor Pluginimport und vor dem Lesen fremder Bildheader, auch für native Decoder.
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_AS, (1536 * 1024 * 1024,) * 2)
resource.setrlimit(resource.RLIMIT_FSIZE, (300 * 1024 * 1024,) * 2)
resource.setrlimit(resource.RLIMIT_NOFILE, (128, 128))


class HEICUnavailable(Exception):
    pass


def heic_header(data):
    if len(data) < 16 or data[4:8] != b'ftyp':
        return False
    size = int.from_bytes(data[:4], 'big')
    if not 16 <= size <= 4096:
        return False
    brands = [data[8:12]] + [data[n:n+4] for n in range(16, min(size, len(data)), 4)]
    return any(brand in {b'heic', b'heix', b'hevc', b'hevx', b'heim', b'heis', b'hevm', b'hevs'} for brand in brands)


def heic_decoder(path):
    if path is None:
        raise HEICUnavailable('The local HEIC/libheif helper is unavailable.')
    loader = importlib.machinery.SourceFileLoader('pmt_heif', path)
    specification = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(specification)
    loader.exec_module(module)
    try:
        return module.Decoder()
    except module.Unavailable as error:
        raise HEICUnavailable(str(error)) from error


def save_frame(image, metadata, index, count, portable):
    from PIL import Image, ImageOps
    width, height = image.size
    if portable:
        image.save(Path.cwd() / f'asset-frame-{index + 1}.png', format='PNG')
    oriented = ImageOps.exif_transpose(image)
    budget = min(16_000_000, 64_000_000 // count)
    downscaled = oriented.width * oriented.height > budget
    if downscaled:
        scale = math.sqrt(budget / (oriented.width * oriented.height))
        oriented.thumbnail((max(1, math.floor(oriented.width * scale)), max(1, math.floor(oriented.height * scale))))
    if oriented.width * oriented.height > budget:
        raise ValueError('image thumbnail exceeds the OCR pixel limit')
    metadata.update({'ocrWidth': oriented.width, 'ocrHeight': oriented.height, 'downscaled': downscaled})
    rgba = oriented.convert('RGBA')
    raster = Image.new('RGB', rgba.size, 'white')
    raster.paste(rgba, mask=rgba.getchannel('A'))
    raster.save(Path.cwd() / f'frame-{index + 1}.png', format='PNG')


def main():
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = 64_000_000
    warnings.simplefilter('error', Image.DecompressionBombWarning)
    formats = {'PNG': 'png', 'JPEG': 'jpg', 'GIF': 'gif', 'TIFF': 'tiff', 'BMP': 'bmp', 'WEBP': 'webp'}
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['capabilities', 'inspect', 'frames'])
    parser.add_argument('source', nargs='?')
    parser.add_argument('--heif-helper')
    parser.add_argument('--probe-heic', action='store_true')
    args = parser.parse_args()
    if args.mode == 'capabilities':
        heic = False
        if args.probe_heic:
            try:
                with heic_decoder(args.heif_helper):
                    heic = True
            except Exception:
                # Optionale Codecfehler dürfen den unabhängigen Pillow-Katalog
                # nicht als fehlend melden. Der echte HEIC-Import meldet den Fehler.
                pass
        print(json.dumps({'available': True, 'heic': heic, 'formats': sorted(formats.values()) + (['heic'] if heic else [])}))
        return
    if args.source is None or os.stat(args.source).st_size > 1_073_741_824:
        raise ValueError('image exceeds the source byte limit')
    with open(args.source, 'rb') as source:
        is_heic = heic_header(source.read(4096))
    frames = []
    if is_heic:
        with heic_decoder(args.heif_helper) as decoder:
            with closing(decoder.frames(args.source, args.mode == 'frames')) as sequence:
                for index, (metadata, image) in enumerate(sequence):
                    if image is not None:
                        try:
                            save_frame(image, metadata, index, metadata['frameCount'], True)
                        finally:
                            image.close()
                    frames.append(metadata)
        extension = 'heic'
    else:
        with Image.open(args.source, formats=list(formats)) as image:
            if image.format not in formats:
                raise ValueError('image format is not supported by the local decoder')
            extension = formats[image.format]
            count = getattr(image, 'n_frames', 1)
            if not 1 <= count <= 1000:
                raise ValueError('image exceeds the frame limit')
            total_pixels = 0
            for index in range(count):
                image.seek(index)
                width, height = image.size
                if width < 1 or height < 1 or width * height > 64_000_000:
                    raise ValueError('image frame exceeds the pixel limit')
                total_pixels += width * height
                if total_pixels > 256_000_000:
                    raise ValueError('image exceeds the total decoded pixel limit')
                image.load()
                metadata = {'width': width, 'height': height}
                if args.mode == 'frames':
                    save_frame(image, metadata, index, count, False)
                frames.append(metadata)
    print(json.dumps({'fileExtension': extension, 'width': frames[0]['width'],
                      'height': frames[0]['height'], 'frameCount': len(frames), 'frames': frames}))


if __name__ == '__main__':
    try:
        main()
    except HEICUnavailable as error:
        print(str(error), file=sys.stderr)
        sys.exit(69)
    except ImportError:
        print('The local Python Pillow decoder is not installed.', file=sys.stderr)
        sys.exit(69)
    except Exception as error:
        print(str(error)[:2048], file=sys.stderr)
        io_errors = {errno.ENOSPC, errno.EDQUOT, errno.EIO, errno.EROFS, errno.EACCES, errno.EPERM, errno.EMFILE, errno.ENFILE}
        sys.exit(74 if isinstance(error, OSError) and error.errno in io_errors else 65)
