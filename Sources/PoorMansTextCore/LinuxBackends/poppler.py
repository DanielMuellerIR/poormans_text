"""Lokaler Poppler-Backendprozess; JSON/PNG sind ausschließlich eigene Ausgaben."""
import json
import errno
import math
import struct
import zlib
import shutil
import subprocess
from pathlib import Path
import resource
import sys

resource.setrlimit(resource.RLIMIT_AS, (2 * 1024**3, 2 * 1024**3))
resource.setrlimit(resource.RLIMIT_FSIZE, (256 * 1024**2, 256 * 1024**2))
try:
    import gi
    gi.require_version('Poppler', '0.18')
    gi.require_foreign('cairo')
    from gi.repository import Poppler, GLib
    import cairo
except (ImportError, ValueError) as error:
    print('Local Python GI Poppler/Cairo backend is unavailable: ' + str(error), file=sys.stderr)
    sys.exit(69)

MAX_PAGES = 1000
MAX_TEXT = 64 * 1024**2
MAX_PAGE_JSON = 16 * 1024**2
MAX_PIXELS = 16_000_000
MAX_TOTAL_PIXELS = 64_000_000
MAX_RECEIPT_SOURCE = 64 * 1024**2
MAX_RECEIPT_PAGE_CHARACTERS = 100_000
MAX_RECEIPT_CHARACTERS = 1_000_000
MAX_RECEIPT_ATTRIBUTES = 32 * 1024**2


def bounded(value, maximum=65536):
    value = value or ''
    if len(value.encode('utf-8')) > maximum:
        raise ValueError('PDF metadata exceeds its size limit')
    return value


def rect(value, page_height=None):
    values = [float(value.x1), float(value.y1), float(value.x2), float(value.y2)]
    if not all(math.isfinite(x) for x in values):
        raise ValueError('PDF rectangle is not finite')
    x1, y1, x2, y2 = values
    if x2 < x1 or y2 < y1:
        raise ValueError('PDF rectangle has negative dimensions')
    return [round(x1, 4), round(page_height - y2 if page_height is not None else y1, 4),
            round(x2 - x1, 4), round(y2 - y1, 4)]


def open_document(source):
    path = Path(source)
    if not path.is_file() or path.stat().st_size > 1024**3:
        raise ValueError('PDF source is not a bounded local file')
    document = Poppler.Document.new_from_file(path.resolve().as_uri(), None)
    if not 1 <= document.get_n_pages() <= MAX_PAGES:
        raise ValueError('PDF page count exceeds the supported range')
    return document


def page_size(page):
    width, height = page.get_size()
    if not all(math.isfinite(x) and 0 < x <= 1_000_000 for x in [width, height]):
        raise ValueError('PDF page dimensions exceed the supported range')
    return width, height


def metadata(document):
    def timestamp(value):
        return value.to_unix() if value is not None else None
    return dict(title=bounded(document.get_title()), author=bounded(document.get_author()),
                subject=bounded(document.get_subject()), keywords=bounded(document.get_keywords()),
                created=timestamp(document.get_creation_date_time()),
                modified=timestamp(document.get_modification_date_time()))


def summary(document, limit):
    pages = []
    for index in range(min(limit, document.get_n_pages())):
        page = document.get_page(index)
        width, height = page_size(page)
        pages.append(dict(number=index + 1, label=bounded(page.get_label(), 1024), width=width, height=height))
    return dict(pageCount=document.get_n_pages(), pages=pages, metadata=metadata(document))


def text_geometry(page, text, height):
    if len(text) > 100_000:
        return [], [], True
    valid, boxes = page.get_text_layout()
    if not valid or len(boxes) != len(text):
        return [], [], bool(text)
    characters = [rect(box, height) for box in boxes]
    lines = []
    offset = 0
    for value in text.splitlines(keepends=True):
        visible = [(i, characters[offset + i]) for i, c in enumerate(value) if not c.isspace()]
        if visible:
            x = min(box[0] for _, box in visible)
            y = min(box[1] for _, box in visible)
            right = max(box[0] + box[2] for _, box in visible)
            top = max(box[1] + box[3] for _, box in visible)
            lines.append(dict(text=value.strip(), bounds=[x, y, right - x, top - y]))
        offset += len(value)
    return characters, lines, False


def links_and_annotations(page):
    _, page_height = page_size(page)
    links = []
    mappings = page.get_link_mapping()
    for mapping in mappings:
        # Der GI-Unionwrapper muss bis zum Kopieren seiner Felder leben.
        action = mapping.action
        uri = None
        destination = None
        if action is not None and action.type == Poppler.ActionType.URI:
            uri_action = action.uri
            uri = bounded(uri_action.uri)
        elif action is not None and action.type == Poppler.ActionType.GOTO_DEST:
            goto = action.goto_dest
            target = goto.dest
            if target is not None and target.page_num > 0:
                destination = target.page_num
        selection = Poppler.Rectangle()
        selection.x1 = mapping.area.x1
        selection.x2 = mapping.area.x2
        selection.y1 = page_height - mapping.area.y2
        selection.y2 = page_height - mapping.area.y1
        label = bounded(page.get_text_for_area(selection))
        links.append(dict(bounds=rect(mapping.area), uri=uri, destinationPage=destination, label=label))
    annotations = []
    mappings = page.get_annot_mapping()
    for number, mapping in enumerate(mappings, 1):
        annotation = mapping.annot
        kind = annotation.get_annot_type().value_nick
        if kind == 'link':
            continue
        author = annotation.get_label() if isinstance(annotation, Poppler.AnnotMarkup) else None
        annotations.append(dict(number=number, kind=kind, contents=bounded(annotation.get_contents(), 1024**2),
                                author=bounded(author), modified=bounded(annotation.get_modified()), bounds=rect(mapping.area)))
    return links, annotations


def retain_render_resolution(destination, width, height, page_width, page_height):
    dpi = (width / page_width * 72, height / page_height * 72)
    if not all(math.isfinite(value) and 0 < value <= 10_000 for value in dpi):
        raise ValueError('the PDF OCR render resolution exceeds its supported range')
    pixels_per_meter = tuple(round(value / 0.0254) for value in dpi)
    if not all(0 < value <= 0xffffffff for value in pixels_per_meter):
        raise ValueError('the PDF OCR render resolution cannot be represented as PNG pHYs')
    payload = struct.pack('>IIB', *pixels_per_meter, 1)
    kind = b'pHYs'
    chunk = struct.pack('>I', len(payload)) + kind + payload + struct.pack('>I', zlib.crc32(kind + payload) & 0xffffffff)
    if destination.stat().st_size > 256 * 1024**2:
        raise ValueError('the PDF OCR PNG exceeds its byte limit')
    temporary = destination.with_name(destination.name + '.resolution')
    # Nur das gerade selbst erzeugte Cairo-PNG ergänzen; keine neue Bildbibliothek
    # und keine Vollkopie des Rasterinhalts im Pythonadressraum.
    with destination.open('rb') as source, temporary.open('xb') as output:
        prefix = source.read(33)
        if len(prefix) != 33 or prefix[:8] != b'\x89PNG\r\n\x1a\n' or prefix[8:16] != b'\x00\x00\x00\rIHDR':
            raise ValueError('the PDF backend produced an invalid PNG header')
        output.write(prefix)
        output.write(chunk)
        shutil.copyfileobj(source, output, 65536)
    temporary.replace(destination)


def receipt_page_attributes(source):
    # Die öffentliche Poppler-GI-API liefert weder /Rotate noch /UserUnit.
    # qpdf liest dieselbe private PDF-Kopie im selben Sandbox-Prozessbaum.
    executable = '/usr/bin/qpdf'
    encrypted = subprocess.run([executable, '--is-encrypted', source], stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, check=False)
    if encrypted.returncode == 0:
        raise ValueError('Password-protected PDFs are unsupported.')
    arguments = [executable, '--json=2', '--json-key=pages', '--json-key=qpdf',
                 '--json-stream-data=none', source]
    with subprocess.Popen(arguments, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL) as process:
        data = process.stdout.read(MAX_RECEIPT_ATTRIBUTES + 1)
        if len(data) > MAX_RECEIPT_ATTRIBUTES:
            process.kill()
            raise ValueError('The PDF exceeds the receipt page attributes limit.')
        if process.wait() != 0:
            raise ValueError('The PDF page attributes are damaged or unreadable.')
    attributes = json.loads(data)
    pages = attributes['pages']
    if not 1 <= len(pages) <= MAX_PAGES:
        raise ValueError(f'The PDF must contain between 1 and {MAX_PAGES} pages.')
    objects = attributes['qpdf'][1]

    def resolve(value):
        for _ in range(64):
            if not isinstance(value, str) or not value.endswith(' R'):
                return value
            value = objects['obj:' + value]['value']
        raise ValueError('Cyclic PDF object reference')

    def box(value):
        coordinates = [resolve(item) for item in resolve(value)]
        if len(coordinates) != 4 or not all(type(x) in (int, float) and math.isfinite(x) for x in coordinates):
            raise ValueError('Unusable PDF page box')
        x1, y1, x2, y2 = coordinates
        return min(x1, x2), min(y1, y2), max(x1, x2), max(y1, y2)

    for index, page in enumerate(pages, 1):
        try:
            leaf = resolve(page['object'])
            unit = resolve(leaf.get('/UserUnit', 1))
            if type(unit) not in (int, float) or not math.isfinite(unit) or unit <= 0:
                raise ValueError('Invalid PDF user unit')
            inherited = {}
            node = leaf
            for _ in range(64):
                for key in ('/MediaBox', '/CropBox', '/Rotate'):
                    if key in node and node[key] is not None:
                        inherited.setdefault(key, node[key])
                if '/Parent' not in node:
                    break
                node = resolve(node['/Parent'])
            else:
                raise ValueError('PDF page parents exceed the depth limit')
            media = box(inherited['/MediaBox'])
            crop = box(inherited['/CropBox']) if '/CropBox' in inherited else media
            crop = (max(crop[0], media[0]), max(crop[1], media[1]), min(crop[2], media[2]), min(crop[3], media[3]))
            rotate = resolve(inherited.get('/Rotate', 0))
            if type(rotate) is not int or rotate % 90 != 0 or crop[0] >= crop[2] or crop[1] >= crop[3]:
                raise ValueError('Invalid PDF rotation or crop bounds')
            yield media, crop, rotate % 360, 72 / (25.4 * unit)
        except (ArithmeticError, KeyError, TypeError, ValueError) as error:
            raise ValueError(f'PDF page {index} has unusable text coordinates.') from error


def receipt_rectangle(bounds, points_per_mm):
    x1, y1, x2, y2 = bounds
    values = (x1 / points_per_mm, y1 / points_per_mm, (x2 - x1) / points_per_mm, (y2 - y1) / points_per_mm)
    if not all(math.isfinite(value) for value in values) or values[2] <= 0 or values[3] <= 0:
        raise ValueError('Unusable PDF bounds')
    return dict(zip(('x', 'y', 'width', 'height'), values))


def receipt_words(page, text, media, crop, rotation, points_per_mm):
    if not text.strip():
        return []
    valid, boxes = page.get_text_layout()
    if not valid or len(boxes) != len(text):
        raise ValueError('The PDF backend did not return matching text and glyph bounds.')
    left, bottom, right, top = crop
    word, words = [], []
    bounds = previous = None
    line = 0

    def finish_word():
        nonlocal word, bounds
        if not word:
            return
        x1, y1, x2, y2 = bounds
        horizontal_margin = max(12, (y2 - y1) * 1.5)
        vertical_margin = (y2 - y1) * 0.75
        if ((left > media[0] and x1 - left < horizontal_margin) or
            (right < media[2] and right - x2 < horizontal_margin) or
            (bottom > media[1] and y1 - bottom < vertical_margin) or
            (top < media[3] and top - y2 < vertical_margin)):
            raise ValueError('The PDF crop boundary is too close to embedded text for reliable extraction.')
        words.append(dict(text=''.join(word), rectangle=receipt_rectangle(bounds, points_per_mm), line=line))
        word, bounds = [], None

    for char, box in zip(text, boxes):
        if char.isspace():
            finish_word()
            if char in '\r\n\v\f\x85\u2028\u2029':
                previous = None
                line += 1
            continue
        # Poppler-Textkoordinaten beginnen oben links in der gedrehten CropBox.
        if rotation == 90:
            glyph = left + box.y1, bottom + box.x1, left + box.y2, bottom + box.x2
        elif rotation == 180:
            glyph = right - box.x2, bottom + box.y1, right - box.x1, bottom + box.y2
        elif rotation == 270:
            glyph = right - box.y2, top - box.x2, right - box.y1, top - box.x1
        else:
            glyph = left + box.x1, top - box.y2, left + box.x2, top - box.y1
        x1, y1, x2, y2 = glyph
        if not all(math.isfinite(value) for value in glyph) or x2 < x1 or y2 <= y1:
            raise ValueError('The PDF contains unusable glyph bounds.')
        if x1 >= right or x2 < left or y1 >= top or y2 <= bottom:
            finish_word()
            previous = None
            line += 1
            continue
        if x1 < left or x2 > right or y1 < bottom or y2 > top:
            raise ValueError('The PDF crop boundary cuts through embedded text.')
        if previous is not None:
            px1, py1, px2, py2 = previous
            height = max(y2 - y1, py2 - py1)
            gap = max(x1 - px2, px1 - x2)
            if gap > max(12, height * 1.5) or abs(y1 + y2 - py1 - py2) > 1.5 * height:
                finish_word()
                line += 1
            elif gap > max(4, height * 0.6):
                # Wie beim PDF-Konverter sichtbare Lücken zwischen Glyphen bewahren,
                # wenn Poppler getrennte Textobjekte ohne Leerzeichen zusammenfügt.
                finish_word()
        word.append(char)
        bounds = ((min(bounds[0], x1), min(bounds[1], y1), max(bounds[2], x2), max(bounds[3], y2))
                  if bounds is not None else glyph)
        previous = glyph
    finish_word()
    return words


def extract_receipt(source, selected_page=None):
    if not Path(source).is_file() or Path(source).stat().st_size > MAX_RECEIPT_SOURCE:
        raise ValueError('The PDF source exceeds the 64 MiB limit or is unreadable.')
    attributes = list(receipt_page_attributes(source))
    document = open_document(source)
    if len(attributes) != document.get_n_pages():
        raise ValueError('The PDF tools disagree about its page count.')
    if selected_page is not None and not 0 <= selected_page < len(attributes):
        raise ValueError('The selected page does not exist in this PDF.')
    indices = range(len(attributes)) if selected_page is None else [selected_page]
    character_counts = []
    remaining = MAX_RECEIPT_CHARACTERS
    protocol_bytes = 0
    for index in indices:
        media, crop, rotation, points_per_mm = attributes[index]
        page = document.get_page(index)
        poppler_crop = page.get_crop_box()
        width, height = page_size(page)
        expected_size = (crop[2] - crop[0], crop[3] - crop[1])
        if rotation in (90, 270):
            expected_size = expected_size[::-1]
        actual = (poppler_crop.x1, poppler_crop.y1, poppler_crop.x2, poppler_crop.y2, width, height)
        if not all(math.isclose(a, b, rel_tol=1e-12, abs_tol=1e-6) for a, b in zip(actual, (*crop, *expected_size))):
            raise ValueError(f'PDF page {index + 1} has unusable text coordinates.')
        text = page.get_text() or ''
        count = len(text.encode('utf-16-le')) // 2
        if count > min(MAX_RECEIPT_PAGE_CHARACTERS, remaining):
            raise ValueError('The PDF exceeds the text extraction limit for this import.')
        remaining -= count
        character_counts.append(count)
        bounds = receipt_rectangle(crop, points_per_mm)
        words = receipt_words(page, text, media, crop, rotation, points_per_mm)
        payload = dict(geometry=dict(bounds=bounds, rotation=rotation), pointsPerMillimeter=points_per_mm, words=words)
        data = json.dumps(payload, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8')
        if len(data) > MAX_PAGE_JSON:
            raise ValueError('The PDF page exceeds the receipt geometry limit.')
        protocol_bytes += len(data)
        if protocol_bytes > 128 * 1024**2:
            raise ValueError('The PDF exceeds the receipt geometry limit.')
        Path(f'receipt-{index + 1}.json').write_bytes(data)
    return dict(characterCounts=character_counts)


def render_page(page, destination, w, h, preserve_resolution=False):
    width, height = page_size(page)
    surface = cairo.ImageSurface(cairo.FORMAT_RGB24, w, h)
    context = cairo.Context(surface)
    context.set_source_rgb(1, 1, 1)
    context.paint()
    context.scale(w / width, h / height)
    if hasattr(page, 'render_full'):
        page.render_full(context, True, Poppler.RenderAnnotsFlags(0))
    else:
        page.render_for_printing_with_options(context, Poppler.PrintFlags.DOCUMENT)
    surface.write_to_png(str(destination))
    surface.finish()
    if preserve_resolution:
        retain_render_resolution(destination, w, h, width, height)

def extract(document, directory, selected, ocr, preserve_resolution=False):
    if not selected or len(selected) > MAX_PAGES or len(set(selected)) != len(selected) or any(type(i) is not int or not 0 <= i < document.get_n_pages() for i in selected):
        raise ValueError('PDF page selection is invalid')
    text_bytes = 0
    annotation_bytes = 0
    annotation_count = 0
    image_pixels = 0
    ocr_pixels = 0
    manifest = []
    protocol_bytes = 0
    image_count = 0
    for index in selected:
        page = document.get_page(index)
        width, height = page_size(page)
        text = page.get_text() or ''
        text_bytes += len(text.encode('utf-8'))
        if text_bytes > MAX_TEXT:
            raise ValueError('PDF text exceeds 64 MiB')
        characters, lines, fallback = text_geometry(page, text, height)
        links, annotations = links_and_annotations(page)
        annotation_count += len(links) + len(annotations)
        annotation_bytes += sum(len(str(v).encode('utf-8')) for a in annotations + links for v in a.values())
        if annotation_count > 8192 or annotation_bytes > 8 * 1024**2:
            raise ValueError('PDF annotations exceed their budget')
        images = []
        scan_candidate = False
        mappings = page.get_image_mapping()
        image_count += len(mappings)
        if image_count > 4096:
            raise ValueError('PDF page has too many images')
        for number, mapping in enumerate(mappings, 1):
            area = rect(mapping.area, height)
            scan_candidate |= area[2] * area[3] >= width * height * .25
            surface = page.get_image(mapping.image_id)
            if surface is None:
                raise ValueError('PDF image could not be decoded')
            w, h = surface.get_width(), surface.get_height()
            if not 0 < w <= MAX_PIXELS or not 0 < h or w > MAX_PIXELS // h:
                raise ValueError('PDF image exceeds its pixel budget')
            image_pixels += w * h
            if image_pixels > MAX_TOTAL_PIXELS:
                raise ValueError('PDF extracted images exceed their pixel budget')
            name = f'page-{index + 1}-image-{number}.png'
            surface.write_to_png(str(directory / name))
            images.append(dict(name=name, width=w, height=h, bounds=area))
            del surface
        raster = None
        if ocr == 'always' or (ocr == 'auto' and (len(text.strip()) < 20 or scan_candidate)):
            scale = min(2.0, math.sqrt(MAX_PIXELS / (width * height)), 16384 / max(width, height))
            w, h = max(1, int(width * scale)), max(1, int(height * scale))
            ocr_pixels += w * h
            if ocr_pixels > MAX_TOTAL_PIXELS:
                raise ValueError('PDF OCR pages exceed their pixel budget')
            name = f'page-{index + 1}-ocr.png'
            render_page(page, directory / name, w, h, preserve_resolution)
            raster = name
        value = dict(number=index + 1, width=width, height=height, label=bounded(page.get_label(), 1024), text=text,
                     characterRects=characters, lines=lines, geometryUnavailable=fallback, links=links,
                     annotations=annotations, images=images, ocrRaster=raster)
        data = json.dumps(value, ensure_ascii=False, separators=(',', ':'), allow_nan=False).encode('utf-8')
        if len(data) > MAX_PAGE_JSON:
            raise ValueError('PDF page geometry exceeds its protocol budget')
        protocol_bytes += len(data)
        if protocol_bytes > 128 * 1024**2:
            raise ValueError('PDF page geometry exceeds its document budget')
        name = f'page-{index + 1}.json'
        (directory / name).write_bytes(data)
        manifest.append(name)
    return dict(pageCount=document.get_n_pages(), pageFiles=manifest, metadata=metadata(document),
                hasAttachments=document.has_attachments())


def main():
    if len(sys.argv) == 2 and sys.argv[1] == 'capabilities':
        return dict(backend='Poppler GI', version=Poppler.get_version(), cairo=cairo.cairo_version_string())
    if len(sys.argv) == 3 and sys.argv[1] == 'validate-attachment':
        path = Path(sys.argv[2])
        if not path.is_file() or path.stat().st_size > 12 * 1024**2:
            raise ValueError('PDF attachment exceeds its size limit')
        with path.open('rb') as source:
            if source.read(5) != b'%PDF-':
                raise ValueError('PDF attachment signature is invalid')
        try:
            document = Poppler.Document.new_from_file(path.resolve().as_uri(), None)
        except GLib.Error as error:
            # Verschlüsselte Anhänge bleiben wie auf dem Mac unverändert erhalten.
            if error.matches(Poppler.error_quark(), Poppler.Error.ENCRYPTED):
                return dict(encrypted=True, pageCount=None)
            raise
        count = document.get_n_pages()
        if count < 1:
            raise ValueError('PDF attachment has no pages')
        return dict(encrypted=False, pageCount=count)
    if len(sys.argv) == 4 and sys.argv[1] == 'summary':
        maximum = int(sys.argv[3])
        if not 1 <= maximum <= 1000:
            raise ValueError('PDF overview page limit is invalid')
        return summary(open_document(sys.argv[2]), maximum)
    if len(sys.argv) in (3, 4) and sys.argv[1] == 'receipt':
        try:
            return extract_receipt(sys.argv[2], int(sys.argv[3]) if len(sys.argv) == 4 else None)
        except FileNotFoundError as error:
            if error.filename != '/usr/bin/qpdf':
                raise
            print('Install qpdf 11 or later to extract PDF receipt data.', file=sys.stderr)
            sys.exit(69)
    if len(sys.argv) == 4 and sys.argv[1] == 'preview':
        if Path(sys.argv[2]).stat().st_size > 128 * 1024**2:
            raise ValueError('preview source exceeds 128 MiB')
        document = open_document(sys.argv[2])
        index = int(sys.argv[3])
        if not 1 <= index <= document.get_n_pages():
            raise ValueError('preview page is outside the source page range')
        page = document.get_page(index - 1)
        width, height = page_size(page)
        scale = min(2.0, 1024 / max(width, height))
        w, h = max(1, int(width * scale)), max(1, int(height * scale))
        render_page(page, Path.cwd() / 'preview.png', w, h)
        return dict(kind='page', index=index, count=document.get_n_pages(), width=w, height=h, downscaled=scale < 1)
    if len(sys.argv) in (6, 7) and sys.argv[1] == 'extract':
        if len(sys.argv) == 7 and sys.argv[6] != '--preserve-resolution':
            raise ValueError('invalid local PDF extraction option')
        mode = sys.argv[5]
        if mode not in ['off', 'auto', 'always']:
            raise ValueError('PDF OCR mode is invalid')
        return extract(open_document(sys.argv[2]), Path(sys.argv[3]), json.loads(sys.argv[4]), mode, len(sys.argv) == 7)
    raise ValueError('invalid local PDF helper command')


if __name__ == '__main__':
    try:
        print(json.dumps(main(), ensure_ascii=False, allow_nan=False, separators=(',', ':')))
    except Exception as error:
        print('Local PDF backend: ' + str(error), file=sys.stderr)
        io_errors = {errno.ENOSPC, errno.EDQUOT, errno.EIO, errno.EROFS, errno.EACCES, errno.EPERM, errno.EMFILE, errno.ENFILE}
        filesystem_error = isinstance(error, OSError) and error.errno in io_errors
        filesystem_error = filesystem_error or getattr(error, 'status', None) == cairo.STATUS_WRITE_ERROR
        sys.exit(74 if filesystem_error else 65)
