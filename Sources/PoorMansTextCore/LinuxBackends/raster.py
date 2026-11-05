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


def validate_png_resolution(path):
    size = path.stat().st_size
    with path.open('rb') as source:
        if source.read(8) != b'\x89PNG\r\n\x1a\n':
            return
        saw_resolution = False
        saw_pixels = False
        for _ in range(100_000):
            header = source.read(8)
            if len(header) != 8:
                raise ValueError('the source PNG chunk header is invalid')
            length, kind = int.from_bytes(header[:4], 'big'), header[4:]
            if length > size - source.tell() - 4:
                raise ValueError('the source PNG chunk length is invalid')
            if kind == b'pHYs':
                if saw_resolution or saw_pixels or length != 9:
                    raise ValueError('the source PNG resolution is ambiguous')
                saw_resolution = True
                data = source.read(9)
                x, y, unit = int.from_bytes(data[:4], 'big'), int.from_bytes(data[4:8], 'big'), data[8]
                if unit not in (0, 1) or x <= 0 or y <= 0 or x != y or (unit == 1 and not 1 <= x * 0.0254 <= 10_000):
                    raise ValueError('the source PNG resolution is invalid or anisotropic')
                source.seek(4, 1)
            else:
                source.seek(length + 4, 1)
            saw_pixels |= kind == b'IDAT'
            if kind == b'IEND':
                return
        raise ValueError('the source PNG chunk count exceeds its limit')


def source_resolution(image):
    if 'dpi' not in image.info:
        if image.info.get('aspect', 1) != 1:
            raise ValueError('structured OCR requires square pixels; anisotropic source resolution is unsupported')
        return None
    values = image.info['dpi']
    if not isinstance(values, (list, tuple)) or len(values) != 2 or any(isinstance(value, bool) for value in values):
        raise ValueError('the source image resolution is invalid')
    try:
        x, y = (float(value) for value in values)
    except (ValueError, TypeError, OverflowError) as error:
        raise ValueError('the source image resolution is invalid') from error
    # Extreme oder richtungsabhängige Quelldichten werden weder geraten noch
    # kosmetisch vereinheitlicht. Fehlende Dichte bleibt ausdrücklich fehlend.
    if not all(math.isfinite(value) and 1 <= value <= 10_000 for value in (x, y)) or x != y:
        raise ValueError('the source image resolution is invalid or anisotropic')
    orientation = image.getexif().get(274, 1)
    if orientation not in range(1, 9):
        raise ValueError('the source image orientation is invalid')
    return (y, x) if orientation in (5, 6, 7, 8) else (x, y)


def save_frame(image, metadata, index, count, portable, preserve_resolution=False):
    from PIL import Image, ImageOps
    width, height = image.size
    if portable:
        image.save(Path.cwd() / f'asset-frame-{index + 1}.png', format='PNG')
    resolution = source_resolution(image) if preserve_resolution else None
    oriented_size = (height, width) if preserve_resolution and image.getexif().get(274, 1) in (5, 6, 7, 8) else (width, height)
    raster, downscaled = render_frame(image, min(16_000_000, 64_000_000 // count))
    metadata.update({'ocrWidth': raster.width, 'ocrHeight': raster.height, 'downscaled': downscaled})
    options = {}
    if resolution is not None:
        options['dpi'] = (resolution[0] * raster.width / oriented_size[0], resolution[1] * raster.height / oriented_size[1])
    raster.save(Path.cwd() / f'frame-{index + 1}.png', format='PNG', **options)


def render_frame(image, budget, maximum_edge=None):
    from PIL import Image, ImageOps
    oriented = ImageOps.exif_transpose(image)
    original = oriented.size
    if maximum_edge is not None:
        oriented.thumbnail((maximum_edge, maximum_edge))
    elif oriented.width * oriented.height > budget:
        scale = math.sqrt(budget / (oriented.width * oriented.height))
        oriented.thumbnail((max(1, math.floor(oriented.width * scale)), max(1, math.floor(oriented.height * scale))))
    if oriented.width * oriented.height > budget:
        raise ValueError('image thumbnail exceeds the pixel limit')
    rgba = oriented.convert('RGBA')
    # Eine neue Pixelfläche übernimmt weder ICC/XMP/EXIF noch PNG-Textchunks.
    raster = Image.new('RGB', rgba.size, 'white')
    raster.paste(rgba, mask=rgba.getchannel('A'))
    return raster, original != raster.size


def save_preview(image, index, count):
    if not 1 <= index <= count:
        raise ValueError('preview frame is outside the source frame range')
    raster, downscaled = render_frame(image, 1024 * 1024, 1024)
    raster.save(Path.cwd() / 'preview.png', format='PNG')
    return dict(kind='frame', index=index, count=count, width=raster.width, height=raster.height, downscaled=downscaled)


def main():
    from PIL import Image
    Image.MAX_IMAGE_PIXELS = 64_000_000
    warnings.simplefilter('error', Image.DecompressionBombWarning)
    formats = {'PNG': 'png', 'JPEG': 'jpg', 'GIF': 'gif', 'TIFF': 'tiff', 'BMP': 'bmp', 'WEBP': 'webp'}
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['capabilities', 'inspect', 'frames', 'preview'])
    parser.add_argument('source', nargs='?')
    parser.add_argument('--index', type=int)
    parser.add_argument('--heif-helper')
    parser.add_argument('--probe-heic', action='store_true')
    parser.add_argument('--preserve-resolution', action='store_true')
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
    if args.mode == 'preview' and (args.index is None or args.index < 1 or os.stat(args.source).st_size > 128 * 1024**2):
        raise ValueError('preview frame or source byte limit is invalid')
    with open(args.source, 'rb') as source:
        is_heic = heic_header(source.read(4096))
    if args.preserve_resolution:
        validate_png_resolution(Path(args.source))
    frames = []
    if is_heic:
        with heic_decoder(args.heif_helper) as decoder:
            with closing(decoder.frames(args.source, args.mode in ['frames', 'preview'])) as sequence:
                for index, (metadata, image) in enumerate(sequence):
                    if image is not None:
                        try:
                            if args.mode == 'preview':
                                if args.index > metadata['frameCount']:
                                    raise ValueError('preview frame is outside the source frame range')
                                if index + 1 == args.index:
                                    print(json.dumps(save_preview(image, args.index, metadata['frameCount'])))
                                    return
                            else:
                                save_frame(image, metadata, index, metadata['frameCount'], True, args.preserve_resolution)
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
            if args.mode == 'preview' and args.index > count:
                raise ValueError('preview frame is outside the source frame range')
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
                if args.mode == 'preview' and index + 1 == args.index:
                    print(json.dumps(save_preview(image, args.index, count)))
                    return
                if args.mode == 'frames':
                    save_frame(image, metadata, index, count, False, args.preserve_resolution)
                frames.append(metadata)
    if args.mode == 'preview':
        raise ValueError('preview frame is unavailable')
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
