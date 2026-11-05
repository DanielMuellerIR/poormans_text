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

# Vor Pluginimport und vor dem Lesen fremder Bildheader, auch für native Decoder.
resource.setrlimit(resource.RLIMIT_AS, (1536 * 1024 * 1024,) * 2)
resource.setrlimit(resource.RLIMIT_FSIZE, (300 * 1024 * 1024,) * 2)
resource.setrlimit(resource.RLIMIT_NOFILE, (128, 128))


def main():
    from PIL import Image, ImageOps
    Image.MAX_IMAGE_PIXELS = 64_000_000
    warnings.simplefilter('error', Image.DecompressionBombWarning)
    formats = {'PNG': 'png', 'JPEG': 'jpg', 'GIF': 'gif', 'TIFF': 'tiff', 'BMP': 'bmp', 'WEBP': 'webp'}
    parser = argparse.ArgumentParser()
    parser.add_argument('mode', choices=['capabilities', 'inspect', 'frames'])
    parser.add_argument('source', nargs='?')
    args = parser.parse_args()
    if args.mode == 'capabilities':
        print(json.dumps({'available': True, 'formats': sorted(formats.values())}))
        return
    if args.source is None or os.stat(args.source).st_size > 1_073_741_824:
        raise ValueError('image exceeds the source byte limit')
    with Image.open(args.source, formats=list(formats)) as image:
        if image.format not in formats:
            raise ValueError('image format is not supported by the local decoder')
        extension = formats[image.format]
        count = getattr(image, 'n_frames', 1)
        if not 1 <= count <= 1000:
            raise ValueError('image exceeds the frame limit')
        budget = min(16_000_000, 64_000_000 // count)
        frames = []
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
            frame = {'width': width, 'height': height}
            if args.mode == 'frames':
                oriented = ImageOps.exif_transpose(image)
                downscaled = oriented.width * oriented.height > budget
                if downscaled:
                    scale = math.sqrt(budget / (oriented.width * oriented.height))
                    size = (max(1, math.floor(oriented.width * scale)), max(1, math.floor(oriented.height * scale)))
                    oriented.thumbnail(size)
                if oriented.width * oriented.height > budget:
                    raise ValueError('image thumbnail exceeds the OCR pixel limit')
                frame.update({'ocrWidth': oriented.width, 'ocrHeight': oriented.height, 'downscaled': downscaled})
                # Transparente Pixel brauchen einen definierten OCR-Hintergrund;
                # bloßes Entfernen des Alphakanals kann sichtbaren Text auslöschen.
                rgba = oriented.convert('RGBA')
                raster = Image.new('RGB', rgba.size, 'white')
                raster.paste(rgba, mask=rgba.getchannel('A'))
                raster.save(Path.cwd() / f'frame-{index + 1}.png', format='PNG')
            frames.append(frame)
        print(json.dumps({'fileExtension': extension, 'width': frames[0]['width'],
                          'height': frames[0]['height'], 'frameCount': count, 'frames': frames}))


if __name__ == '__main__':
    try:
        main()
    except ImportError:
        print('The local Python Pillow decoder is not installed.', file=sys.stderr)
        sys.exit(69)
    except Exception as error:
        print(str(error)[:2048], file=sys.stderr)
        io_errors = {errno.ENOSPC, errno.EDQUOT, errno.EIO, errno.EROFS, errno.EACCES, errno.EPERM, errno.EMFILE, errno.ENFILE}
        sys.exit(74 if isinstance(error, OSError) and error.errno in io_errors else 65)
