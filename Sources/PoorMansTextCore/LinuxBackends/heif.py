"""Explizite libheif-CAPI, ausschließlich im begrenzten Raster-Worker laden."""
import ctypes as C
import os
from pathlib import Path

HEVC = 1
RGB = 1
INTERLEAVED_RGBA = 11
INTERLEAVED_CHANNEL = 10

class Unavailable(Exception):
    pass

class Error(C.Structure):
    _fields_ = [('code', C.c_int), ('subcode', C.c_int), ('message', C.c_char_p)]

class Decoder:

    def __init__(self):
        self.library = None
        for path in ['/usr/lib/x86_64-linux-gnu/libheif.so.1', '/usr/lib/libheif.so.1']:
            if Path(path).is_file():
                try:
                    self.library = C.CDLL(path)
                except OSError as error:
                    raise Unavailable('The local distro libheif decoder cannot be loaded.') from error
                break
        if self.library is None:
            raise Unavailable('The local distro libheif HEVC decoder is not installed.')
        signatures = {
            'heif_init': (Error, [C.c_void_p]),
            'heif_deinit': (None, []),
            'heif_get_version': (C.c_char_p, []),
            'heif_have_decoder_for_format': (C.c_int, [C.c_int]),
            'heif_context_alloc': (C.c_void_p, []),
            'heif_context_free': (None, [C.c_void_p]),
            'heif_context_set_maximum_image_size_limit': (None, [C.c_void_p, C.c_int]),
            'heif_context_set_max_decoding_threads': (None, [C.c_void_p, C.c_int]),
            'heif_context_read_from_file': (Error, [C.c_void_p, C.c_char_p, C.c_void_p]),
            'heif_context_get_number_of_top_level_images': (C.c_int, [C.c_void_p]),
            'heif_context_get_list_of_top_level_image_IDs': (C.c_int, [C.c_void_p, C.POINTER(C.c_uint32), C.c_int]),
            'heif_context_get_image_handle': (Error, [C.c_void_p, C.c_uint32, C.POINTER(C.c_void_p)]),
            'heif_image_handle_release': (None, [C.c_void_p]),
            'heif_decode_image': (Error, [C.c_void_p, C.POINTER(C.c_void_p), C.c_int, C.c_int, C.c_void_p]),
            'heif_image_release': (None, [C.c_void_p]),
            'heif_image_get_width': (C.c_int, [C.c_void_p, C.c_int]),
            'heif_image_get_height': (C.c_int, [C.c_void_p, C.c_int]),
            'heif_image_get_plane_readonly': (C.c_void_p, [C.c_void_p, C.c_int, C.POINTER(C.c_int)]),
        }
        for field in ['width', 'height', 'ispe_width', 'ispe_height']:
            signatures['heif_image_handle_get_' + field] = (C.c_int, [C.c_void_p])
        try:
            for name, (result, arguments) in signatures.items():
                function = getattr(self.library, name)
                function.restype = result
                function.argtypes = arguments
        except AttributeError as error:
            raise Unavailable('The local libheif ABI is incomplete.') from error
        # Plugins erst nach den vom Aufrufer gesetzten Prozesslimits laden.
        initialization = self.library.heif_init(None)
        if initialization.code:
            # Der API-Vertrag paart jeden init-Aufruf mit deinit, auch hier
            # vor dem Lesen einer Quelle. Pluginfehler sind Toolverfügbarkeit.
            self.library.heif_deinit()
            self.library = None
            raise Unavailable(f'The local libheif/codec initialization failed '
                              f'(code {initialization.code}, subcode {initialization.subcode}).')
        if self.library.heif_have_decoder_for_format(HEVC) != 1:
            self.library.heif_deinit()
            raise Unavailable('The local libheif HEVC decoder plugin is not installed.')

    @staticmethod
    def check(error):
        if error.code:
            raise ValueError('libheif: ' + (error.message or b'decoder error').decode('utf-8', errors='replace')[:1000])

    def close(self):
        if self.library is not None:
            self.library.heif_deinit()
            self.library = None

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()

    def frames(self, source, render):
        from PIL import Image
        library = self.library
        context = library.heif_context_alloc()
        if not context:
            raise MemoryError('libheif context allocation failed')
        try:
            library.heif_context_set_maximum_image_size_limit(context, 32768)
            library.heif_context_set_max_decoding_threads(context, 1)
            self.check(library.heif_context_read_from_file(context, os.fsencode(source), None))
            count = library.heif_context_get_number_of_top_level_images(context)
            if not 1 <= count <= 1000:
                raise ValueError('HEIC has no supported still images or exceeds the frame limit')
            ids = (C.c_uint32 * count)()
            if library.heif_context_get_list_of_top_level_image_IDs(context, ids, count) != count:
                raise ValueError('HEIC frame list changed')
            total = 0
            for item in ids:
                handle = C.c_void_p()
                decoded = C.c_void_p()
                try:
                    self.check(library.heif_context_get_image_handle(context, item, C.byref(handle)))
                    dimensions = [getattr(library, 'heif_image_handle_get_' + field)(handle) for field in ['width', 'height', 'ispe_width', 'ispe_height']]
                    width, height, original_width, original_height = dimensions
                    for checked_width, checked_height in [(width, height), (original_width, original_height)]:
                        if (checked_width < 1 or checked_height < 1 or checked_width > 32768
                                or checked_height > 32768 or checked_width * checked_height > 64_000_000):
                            raise ValueError('HEIC exceeds predecode dimension/pixel limit')
                    total += max(width * height, original_width * original_height)
                    if total > 256000000:
                        raise ValueError('HEIC exceeds total decoded pixel limit')
                    # NULL-Optionen wenden die HEIF-Transformationen genau einmal an.
                    self.check(library.heif_decode_image(handle, C.byref(decoded), RGB, INTERLEAVED_RGBA, None))
                    if library.heif_image_get_width(decoded, INTERLEAVED_CHANNEL) != width or library.heif_image_get_height(decoded, INTERLEAVED_CHANNEL) != height:
                        raise ValueError('HEIC decoded dimensions disagree')
                    stride = C.c_int()
                    pointer = library.heif_image_get_plane_readonly(decoded, INTERLEAVED_CHANNEL, C.byref(stride))
                    span = stride.value * height
                    if not pointer or stride.value < width * 4 or span > 256000000:
                        raise ValueError('HEIC decoded buffer exceeds limit')
                    if render:
                        # frombytes kopiert vor dem Freigeben des nativen Bildpuffers.
                        image = Image.frombytes('RGBA', (width, height), C.string_at(pointer, span), 'raw', 'RGBA', stride.value)
                        yield ({'width': width, 'height': height, 'ispeWidth': original_width, 'ispeHeight': original_height, 'frameCount': count}, image)
                    else:
                        yield ({'width': width, 'height': height, 'ispeWidth': original_width, 'ispeHeight': original_height, 'frameCount': count}, None)
                finally:
                    if decoded.value:
                        library.heif_image_release(decoded)
                    if handle.value:
                        library.heif_image_handle_release(handle)
        finally:
            library.heif_context_free(context)
