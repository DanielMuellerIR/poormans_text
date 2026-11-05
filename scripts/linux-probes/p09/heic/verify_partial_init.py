"""Echte fehlgeschlagene libheif-Initialisierung: kein Dokumentstart, genau ein deinit."""
import argparse
import ctypes
import importlib.util
import json
import resource

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_AS, (1536 * 1024 * 1024,) * 2)
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--helper', required=True)
args = parser.parse_args()
specification = importlib.util.spec_from_file_location('pmt_heif', args.helper)
module = importlib.util.module_from_spec(specification)
specification.loader.exec_module(module)
calls = []
real_load = ctypes.CDLL


class Function:
    def __init__(self, function, name):
        object.__setattr__(self, 'function', function)
        object.__setattr__(self, 'name', name)

    def __setattr__(self, name, value):
        setattr(self.function, name, value)

    def __call__(self, *arguments):
        calls.append(self.name)
        return self.function(*arguments)


class Library:
    def __init__(self, path):
        self.library = real_load(path)
        self.functions = {}

    def __getattr__(self, name):
        if name not in {'heif_init', 'heif_deinit', 'heif_context_read_from_file'}:
            return getattr(self.library, name)
        if name not in self.functions:
            self.functions[name] = Function(getattr(self.library, name), name)
        return self.functions[name]


ctypes.CDLL = Library
try:
    try:
        module.Decoder()
    except module.Unavailable as error:
        assert calls == ['heif_init', 'heif_deinit'], calls
        print(json.dumps({'classification': 'Unavailable', 'exit': 69,
                          'nativeCalls': calls, 'nativeSourceReads': 0, 'reason': str(error)}))
    else:
        raise AssertionError('Expected real partial initialization failure')
finally:
    ctypes.CDLL = real_load
