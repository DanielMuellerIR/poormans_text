"""Legacy-DOC ausschließlich im lokalen PMT-PID-/Netzwerk-Namespace exportieren."""
import argparse
import hashlib
import errno
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import resource
import stat
import subprocess
import sys
import secrets
import time

MAX_SOURCE_BYTES = 1024 * 1024 * 1024
MAX_HTML_BYTES = 128 * 1024 * 1024
MAX_REFERENCE_BYTES = 64 * 1024 * 1024
MAX_ADDRESS_SPACE = 3 * 1024 * 1024 * 1024

resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_FSIZE, (256 * 1024 * 1024,) * 2)
resource.setrlimit(resource.RLIMIT_NOFILE, (512, 512))

resource.setrlimit(resource.RLIMIT_AS, (MAX_ADDRESS_SPACE, MAX_ADDRESS_SPACE))

try:
    import uno
    import unohelper
    from com.sun.star.beans import PropertyValue
    from com.sun.star.task import XInteractionHandler
    from com.sun.star.io import IOException as UNOIOException
    from com.sun.star.document.MacroExecMode import NEVER_EXECUTE
    from com.sun.star.document.UpdateDocMode import NO_UPDATE
except ImportError:
    print('Python UNO is required for the local LibreOffice DOC backend.', file=sys.stderr)
    sys.exit(69)


PROFILE = '''<?xml version="1.0" encoding="UTF-8"?>
<oor:items xmlns:oor="http://openoffice.org/2001/registry">
 <item oor:path="/org.openoffice.Office.Common/Security/Scripting">
  <prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop>
  <prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop>
  <prop oor:name="SecureURL" oor:op="fuse"><value/></prop>
 </item>
 <item oor:path="/org.openoffice.Office.Writer/Content/Update">
  <prop oor:name="Link" oor:op="fuse"><value>2</value></prop>
 </item>
</oor:items>'''


class Images(HTMLParser):
    def __init__(self):
        super().__init__()
        self.references = []

    def handle_starttag(self, tag, attributes):
        if tag.lower() == 'img':
            self.references.append(dict(attributes).get('src', ''))


def fingerprint(path):
    digest = hashlib.sha256()
    size = 0
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(descriptor, 'rb') as source:
        if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
            raise ValueError('the verified DOC snapshot is not a regular file')
        while chunk := source.read(256 * 1024):
            size += len(chunk)
            if size > MAX_SOURCE_BYTES:
                raise ValueError('the DOC source exceeds 1 GiB')
            digest.update(chunk)
    return digest.hexdigest(), size


class ExportOutputError(Exception):
    def __init__(self, error):
        code = getattr(error, 'ErrCode', None)
        detail = type(error).__name__
        if isinstance(code, int):
            detail += '; code ' + str(code)
        super().__init__('The local LibreOffice DOC export could not write its output (' + detail + ').')


class RejectInteraction(unohelper.Base, XInteractionHandler):
    def handle(self, request):
        for continuation in request.getContinuations():
            abort = continuation.queryInterface(uno.getTypeByName('com.sun.star.task.XInteractionAbort'))
            if abort is not None:
                abort.select()
                return
        raise RuntimeError('LibreOffice requested an interaction which cannot be safely accepted')


def properties(**values):
    return tuple(PropertyValue(Name=name, Value=value) for name, value in values.items())


def export_document(source, root):
    profile = root / 'profile'
    user = profile / 'user'
    user.mkdir(parents=True, mode=0o700)
    (user / 'registrymodifications.xcu').write_text(PROFILE, encoding='utf-8')
    pipe_name = 'pmt-doc-' + secrets.token_hex(24)
    environment = {'PATH': '/usr/bin:/bin', 'HOME': str(root / 'home'),
                   'TMPDIR': str(root / 'tmp'), 'SAL_USE_VCLPLUGIN': 'svp', 'LANG': 'C.UTF-8'}
    command = ['/usr/bin/libreoffice', '-env:UserInstallation=' + profile.as_uri(),
               '--headless', '--nologo', '--nodefault', '--norestore',
               '--accept=pipe,name=' + pipe_name + ';urp;StarOffice.ComponentContext']
    document = desktop = None
    with (root / 'libreoffice.log').open('xb') as log:
        office = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=log, stderr=log,
                                  env=environment, close_fds=True)
        try:
            local = uno.getComponentContext()
            resolver = local.ServiceManager.createInstanceWithContext('com.sun.star.bridge.UnoUrlResolver', local)
            deadline = time.monotonic() + 10
            while True:
                try:
                    context = resolver.resolve('uno:pipe,name=' + pipe_name + ';urp;StarOffice.ComponentContext')
                    break
                except Exception:
                    if office.poll() is not None:
                        raise ValueError('the isolated LibreOffice process exited before UNO connected')
                    if time.monotonic() >= deadline:
                        raise subprocess.TimeoutExpired(command, 10)
                    time.sleep(.05)
            desktop = context.ServiceManager.createInstanceWithContext('com.sun.star.frame.Desktop', context)
            # Diese Flags sind unveränderliche Produktvorgaben. Unsichere Kontrollen
            # gehören ausschließlich in den getrennten Prüf-Harness.
            descriptor = properties(MacroExecutionMode=uno.Any('short', NEVER_EXECUTE),
                UpdateDocMode=uno.Any('short', NO_UPDATE), ReadOnly=True, Hidden=True,
                Silent=True, OpenNewView=True, PickListEntry=False,
                InteractionHandler=RejectInteraction())
            document = desktop.loadComponentFromURL(source.as_uri(), '_blank', 0, descriptor)
            if document is None or not document.supportsService('com.sun.star.text.TextDocument'):
                raise ValueError('LibreOffice did not load a Word text document')
            for name, filter_name, options in [('html', 'HTML (StarWriter)', None), ('text', 'Text (encoded)', 'UTF8')]:
                output = root / name
                output.mkdir(mode=0o700)
                destination = output / ('document.html' if name == 'html' else 'document.txt')
                settings = {'FilterName': filter_name, 'Overwrite': False}
                if options is not None:
                    settings['FilterOptions'] = options
                try:
                    document.storeToURL(destination.as_uri(), properties(**settings))
                except UNOIOException as error:
                    # UNO-I/O-Ausnahmen erben nicht von Python-OSError. Nur der
                    # Schreibaufruf wird hier als Export-Dateisystemfehler behandelt.
                    raise ExportOutputError(error) from error
            return root / 'html/document.html', root / 'text/document.txt'
        finally:
            try:
                if document is not None:
                    document.close(True)
                if desktop is not None:
                    desktop.terminate()
            finally:
                try:
                    office.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    office.terminate()
                    try:
                        office.wait(timeout=1)
                    except subprocess.TimeoutExpired:
                        office.kill()
                        office.wait()


def inspect_output(output):
    resources = []
    size = 0
    for path in output.rglob('*'):
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not (stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode)):
            raise ValueError('LibreOffice produced an unsafe resource type')
        if stat.S_ISREG(info.st_mode):
            size += info.st_size
            resources.append(path)
            if size > 512 * 1024 * 1024 or len(resources) > 4096:
                raise ValueError('LibreOffice output exceeds the resource budget')
    return resources


def bounded_bytes(path, maximum, subject):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    with os.fdopen(descriptor, 'rb') as source:
        info = os.fstat(source.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise ValueError(subject + ' exceeds its byte budget or is not a regular file')
        data = bytearray()
        while True:
            chunk = source.read(min(262144, maximum + 1 - len(data)))
            if not chunk:
                break
            data.extend(chunk)
            if len(data) > maximum:
                raise ValueError(subject + ' grew beyond its byte budget')
    return bytes(data)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source', type=Path, nargs='?')
    parser.add_argument('--capabilities', action='store_true')
    args = parser.parse_args()
    if args.capabilities:
        print(json.dumps({'pythonUNO': True, 'libreoffice': os.access('/usr/bin/libreoffice', os.X_OK)}))
        return
    if args.source is None:
        parser.error('a DOC snapshot is required')
    root = Path.cwd()
    for name in ['home', 'tmp']:
        (root / name).mkdir(mode=0o700)
    original = fingerprint(args.source)
    html, text = export_document(args.source, root)
    resources = inspect_output(root / 'html')
    inspect_output(root / 'text')
    if original != fingerprint(args.source):
        raise ValueError('the verified DOC snapshot changed between export runs')
    html_bytes = bounded_bytes(html, MAX_HTML_BYTES, 'the DOC HTML export')
    charset = re.search(br'charset\s*=\s*["\']?([a-zA-Z0-9_-]+)', html_bytes[:4096], re.IGNORECASE)
    encoding = charset.group(1).decode('ascii') if charset else 'utf-8'
    content = html_bytes.decode(encoding)
    encoded = content.encode('utf-8')
    if len(encoded) > MAX_HTML_BYTES:
        raise ValueError('the UTF-8 DOC HTML export exceeds its byte budget')
    html.write_bytes(encoded)
    reference = bounded_bytes(text, MAX_REFERENCE_BYTES, 'the DOC text export').decode('utf-8-sig')
    (root / 'reference.txt').write_text(reference, encoding='utf-8')
    images = Images()
    images.feed(content)
    print(json.dumps({'loadMacroExecutionMode': NEVER_EXECUTE, 'loadUpdateDocMode': NO_UPDATE, 'htmlFile': str(html.relative_to(root)), 'referenceFile': 'reference.txt',
                      'sourceSHA256': original[0], 'sourceByteCount': original[1],
                      'imageReferenceCount': len(images.references),
                      'imageResourceCount': sum(p.suffix.lower() in ['.png', '.jpg', '.jpeg', '.gif', '.bmp', '.tif', '.tiff', '.webp', '.svg', '.wmf', '.emf'] for p in resources)}))


if __name__ == '__main__':
    try:
        main()
    except FileNotFoundError as error:
        print(str(error)[:2048], file=sys.stderr)
        sys.exit(69 if error.filename == '/usr/bin/libreoffice' else 65)
    except ExportOutputError as error:
        print(str(error), file=sys.stderr)
        sys.exit(74)
    except subprocess.TimeoutExpired:
        print('The local LibreOffice DOC export exceeded its time limit.', file=sys.stderr)
        sys.exit(124)
    except OSError as error:
        print(str(error)[:2048], file=sys.stderr)
        sys.exit(74 if error.errno in (errno.ENOSPC, errno.EDQUOT, errno.EIO, errno.EROFS, errno.EACCES) else 65)
    except Exception as error:
        print(str(error)[:2048], file=sys.stderr)
        sys.exit(65)
