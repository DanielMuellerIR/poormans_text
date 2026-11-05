"""Lokaler Poppler-Backendprozess; JSON/PNG sind ausschließlich eigene Ausgaben."""
import json
import errno
import math
from pathlib import Path
import resource
import sys

resource.setrlimit(resource.RLIMIT_AS, (2 * 1024**3, 2 * 1024**3))
resource.setrlimit(resource.RLIMIT_FSIZE, (256 * 1024**2, 256 * 1024**2))
try:
    import gi
    gi.require_version('Poppler', '0.18')
    gi.require_foreign('cairo')
    from gi.repository import Poppler
    import cairo
except (ImportError, ValueError) as error:
    print('Local Python GI Poppler/Cairo backend is unavailable: ' + str(error), file=sys.stderr)
    sys.exit(69)

MAX_PAGES = 1000
MAX_TEXT = 64 * 1024**2
MAX_PAGE_JSON = 16 * 1024**2
MAX_PIXELS = 16_000_000
MAX_TOTAL_PIXELS = 64_000_000


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


def extract(document, directory, selected, ocr):
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
            surface = cairo.ImageSurface(cairo.FORMAT_RGB24, w, h)
            context = cairo.Context(surface)
            context.set_source_rgb(1, 1, 1)
            context.paint()
            context.scale(w / width, h / height)
            if hasattr(page, 'render_full'):
                page.render_full(context, True, Poppler.RenderAnnotsFlags(0))
            else:
                page.render_for_printing_with_options(context, Poppler.PrintFlags.DOCUMENT)
            surface.write_to_png(str(directory / name))
            surface.finish()
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
    if len(sys.argv) == 4 and sys.argv[1] == 'summary':
        maximum = int(sys.argv[3])
        if not 1 <= maximum <= 1000:
            raise ValueError('PDF overview page limit is invalid')
        return summary(open_document(sys.argv[2]), maximum)
    if len(sys.argv) == 6 and sys.argv[1] == 'extract':
        mode = sys.argv[5]
        if mode not in ['off', 'auto', 'always']:
            raise ValueError('PDF OCR mode is invalid')
        return extract(open_document(sys.argv[2]), Path(sys.argv[3]), json.loads(sys.argv[4]), mode)
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
